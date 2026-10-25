// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Layoffs are a cut a firm can come back from (docs/plans/factory-floors.md
/// §7 Q11: layoffs → idle → close → nationalise or sell). A template floor
/// with its handlers emptied ships nothing but keeps its station jobs, so a
/// layoff may never take the last handler of a kind, and whoever takes a
/// plant over (or the firm itself, once healthy) hires the laid-off staff
/// back: a reopened plant on a stripped roster would ship nothing for ever.
library;

import 'package:acro_space_simulator/application/factory/colony_floor_measurer.dart';
import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/firm_policy.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_measure.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

void main() {
  // The whole ladder on the TEMPLATE crew: one handler a week down to one
  // of each kind, then idle, then close. Resolving the offer reopens it on
  // the template's full roster, and that floor really ships.
  test('a closed template plant reopens on its full roster', () {
    final sim = economyColony();
    final mill = specOf('steelmill');
    final lot = placePlant(sim, 'steelmill');
    final template = factoryTemplateFor('steelmill')!.roster;
    makeLosing(sim, lot);
    // 200 days: the port-era mill crews 18 handlers, and the ladder lays
    // off one a week before it idles and closes (it stops early on close).
    runDays(sim, 200, specs: [mill], after: () => sim.floorThrottleOf(lot) == 0);
    expect(sim.firmBookOf(lot)!.health, FirmHealth.closed);
    final cut = sim.factoryFloors[lot]!.blueprint.roster;
    for (final k in template.keys) {
      expect(cut[k], 1, reason: '$k: cut to one, never to none');
    }
    expect(sim.colonyEconomy.laidOff[lot], isNotEmpty);

    expect(sim.resolveFirmOffer(lot, ClosureOption.sellToNewFirm), isTrue);
    final rec = sim.factoryFloors[lot]!;
    expect(rec.blueprint.roster, template, reason: 'the staff are rehired');
    expect(rec.dirty, isTrue, reason: 'the fuller floor is re-measured');
    expect(sim.colonyEconomy.laidOff[lot], isNull);
    final r = measureBlueprint(rec.blueprint, buildFloorForMeasure,
        settings: measureSettingsFor('steelmill'));
    expect(r.outPerS['steel'] ?? 0, greaterThan(0));
  });

  // Nationalising rehires too: a state plant on a stripped roster would
  // charge its station wages as a standing industry deficit.
  test('nationalising a cut plant rehires its staff', () {
    final r = losingMill();
    expect(r.sim.factoryFloors[r.lot]!.blueprint.roster[HandlerKind.onFoot],
        1);
    expect(r.sim.resolveFirmOffer(r.lot, ClosureOption.nationalise), isTrue);
    expect(r.sim.factoryFloors[r.lot]!.blueprint.roster[HandlerKind.onFoot],
        2);
  });

  // A firm back in health takes back whom it let go.
  test('a firm that recovers hires its laid-off staff back', () {
    final r = losingMill();
    final sim = r.sim;
    expect(sim.resolveFirmOffer(r.lot, ClosureOption.sellToNewFirm), isTrue);
    // Cut again by hand, as a layoff does, then the plant runs at a
    // profit: the template rates, the template jobs.
    final rec = sim.factoryFloors[r.lot]!;
    rec.blueprint.roster[HandlerKind.onFoot] = 1;
    sim.colonyEconomy.laidOff[r.lot] = {HandlerKind.onFoot: 1};
    rec.rates = flatRatesOf(specOf('steelmill'));
    runDays(sim, 2, specs: [specOf('steelmill')]);
    expect(sim.firmBookOf(r.lot)!.health, FirmHealth.healthy);
    expect(rec.blueprint.roster[HandlerKind.onFoot], 2);
    expect(sim.colonyEconomy.laidOff[r.lot], isNull);
  });

  // The record of who was let go is saved: a reload must not forget to
  // hire them back.
  test('laid-off staff survive a save', () {
    final r = losingMill();
    final saved = r.sim.colonyEconomy.laidOff[r.lot];
    expect(saved, {HandlerKind.onFoot: 1});
    final loaded = reload(r.sim.toJson());
    expect(loaded.colonyEconomy.laidOff[r.lot], saved);
    expect(loaded.resolveFirmOffer(r.lot, ClosureOption.nationalise), isTrue);
    expect(loaded.factoryFloors[r.lot]!.blueprint.roster[HandlerKind.onFoot],
        2);
  });

  // The notices list is bounded even when no host drains it.
  test('economy notices keep only the newest few', () {
    final sim = economyColony();
    for (var i = 0; i < kEconomyNoticeCap + 5; i++) {
      sim.pushEconomyNotice('n$i');
    }
    expect(sim.colonyEconomy.notices, hasLength(kEconomyNoticeCap));
    expect(sim.colonyEconomy.notices.last, 'n${kEconomyNoticeCap + 4}');
    expect(sim.drainEconomyNotices(), hasLength(kEconomyNoticeCap));
    expect(sim.colonyEconomy.notices, isEmpty);
  });
}

