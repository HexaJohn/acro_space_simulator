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
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
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

  // The starved-of-staff rule (`city_economy.dart` library doc). The labour
  // market staffs flat buildings first, then floors by bid (a losing
  // private firm bids last), each a balanced crew, so a floor whose crew
  // needs a tier nobody is left in gets no one. That is what stalled the
  // test above: by ~day 100 its allocation share had fallen to 0 as its
  // roster thinned, the floor booked no work at all, and the day close
  // skipped every such day as "the colony refused the plant", freezing the
  // firm at distressed for ever. Here the
  // colony has no one above unskilled (the mix is pinned each tick) and
  // the mill's handlers are skilled: its share is 0 from the first tick,
  // with its inputs in stock. It must still be judged, on what owning the
  // plant costs, and walk idle → close → offer.
  test('a firm starved of staff by the labour market still closes', () {
    final sim = economyColony();
    final mill = specOf('steelmill');
    final lot = placePlant(sim, 'steelmill');
    // One of each kind: nothing left to lay off, so the ladder is idle,
    // then a close after the distress grace.
    final roster = sim.factoryFloors[lot]!.blueprint.roster;
    for (final k in roster.keys.toList()) {
      roster[k] = 1;
    }
    final mix = sim.colonyEconomy.labour.mix;
    void pinMix() => mix
      ..clear()
      ..addAll({for (final t in SkillTier.values) t: 0.0})
      ..[SkillTier.unskilled] = 1.0;
    final ticks = (45 * kColonyDaySec / kEconTickS).round();
    var sawStarved = false;
    for (var i = 0; i < ticks; i++) {
      sim.population = kEconPopulation;
      pinMix();
      holdStock(sim, mill);
      sim.advance(kEconTickS);
      if ((sim.colonyEconomy.staffStarvedS[lot] ?? 0) > 0) sawStarved = true;
      if (sim.floorThrottleOf(lot) == 0) break;
    }
    expect(sawStarved, isTrue, reason: 'the market gave it no one');
    expect(sim.colonyEconomy.labourMarketShare[lot] ?? 1,
        lessThan(kStaffStarvedShare));
    final pnl = sim.colonyEconomy.lastPnl[lot]!;
    expect(pnl.wages, 0, reason: 'nobody worked');
    expect(pnl.revenue, 0);
    expect(pnl.capital, greaterThan(0),
        reason: 'an unstaffed day books what owning the plant costs');
    expect(sim.firmBookOf(lot)!.health, FirmHealth.closed);
    expect(sim.pendingFirmOffers.map((o) => o.site), contains(lot));
  });

  // The other idle cause stays exempt: no inputs in stock is the colony's
  // stall, not the firm's failing, even while the market staffs no one
  // (a floor with no inputs to work posts its jobs all the same).
  test('a plant the colony starves of inputs is not judged', () {
    final sim = economyColony();
    final mill = specOf('steelmill');
    final lot = placePlant(sim, 'steelmill');
    final mix = sim.colonyEconomy.labour.mix;
    final ticks = (20 * kColonyDaySec / kEconTickS).round();
    for (var i = 0; i < ticks; i++) {
      sim.population = kEconPopulation;
      mix
        ..clear()
        ..addAll({for (final t in SkillTier.values) t: 0.0})
        ..[SkillTier.unskilled] = 1.0;
      holdStock(sim, mill, inputs: 0);
      sim.advance(kEconTickS);
    }
    expect(sim.colonyEconomy.staffStarvedS[lot], isNull);
    final book = sim.firmBookOf(lot)!;
    expect(book.health, FirmHealth.healthy);
    expect(book.costPerS, 0, reason: 'no day was booked');
    expect(sim.floorThrottleOf(lot), 1);
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

