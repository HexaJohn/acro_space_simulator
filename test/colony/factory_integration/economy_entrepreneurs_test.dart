// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Entrepreneurs end to end through the colony (docs/plans/dynamic-markets.md
/// phase 4): a good whose margin stays high draws a new private firm to
/// found a plant for it, within the colony's rules.
library;

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_control.dart';
import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_entrepreneurs.dart';
import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/colony_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/entrepreneurs.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/firm_policy.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/learning.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'economy_fixture.dart';
import 'factory_colony_fixture.dart';

/// Steel and tubes the colony's (absent) consumers want, units/s: twice a
/// mill's 1.5 steel and 0.4 tubes, so the good stays short even after one
/// mill opens.
const double kSteelWanted = 3.0;
const double kTubesWanted = 0.8;

/// Ore the colony's (absent) mines bring in, units/s: one Mine's worth, and
/// the store held at [kOreHeld], so a mill has ore to buy.
const double kOreMined = 2.0;
const double kOreHeld = 3000;

/// A Mars colony short of steel: no mill, no port (no export floor, so the
/// price floats on the colony's own supply and demand), consumers drawing
/// [kSteelWanted]. Mars, not Earth: an Earth colony trades at Earth's
/// mature prices, where a mill earns the normal margin and no firm founds.
CitySim shortOfSteel({Economy economy = Economy.capitalism}) =>
    economyColony(bodyId: 'mars', economy: economy);

/// Runs [sim] for [days] economy days, its consumers wanting steel and its
/// mines bringing in ore every tick (the people held as [runDays] holds
/// them). [after] runs after every tick; stop early by returning true.
///
/// Loyalty is held too: a Mars starter colony of 300 turns Defiant inside a
/// month, and a striking colony sees no foundings (tested on its own
/// below), a colony story the other tests aren't about.
void driveShortage(CitySim sim, double days,
    {double steel = kSteelWanted,
    double tubes = kTubesWanted,
    bool cartOff = false,
    bool Function()? after}) {
  final ticks = (days * kColonyDaySec / kEconTickS).round();
  for (var i = 0; i < ticks; i++) {
    sim.population = kEconPopulation;
    sim.loyalty.level = 1;
    sim.stock[Commodity.ore] = kOreHeld;
    final e = sim.colonyEconomy;
    e.addFlow(Commodity.ore, kOreMined, kEconTickS);
    e.addFlow(Commodity.steel, -steel, kEconTickS);
    e.addFlow(Commodity.tubes, -tubes, kEconTickS);
    if (cartOff) {
      // Carted off unsold ([holdStock]'s `wanted: false`): a mill against
      // a full warehouse stands its staff down and books nothing.
      sim.stock[Commodity.steel] = 0;
      sim.stock[Commodity.tubes] = 0;
    }
    sim.advance(kEconTickS);
    if (after != null && after()) return;
  }
}

/// Runs [sim] short of steel until its first founding (at most [maxDays]),
/// noting the economy day steel's pressure first counted.
({int? firstPressureDay, int? foundedDay, Vec2? expectedSite})
    runToFounding(CitySim sim, {double maxDays = 120}) {
  final f = sim.colonyEconomy.founding;
  int? first;
  Vec2? expected;
  var lastDay = f.daySerial;
  driveShortage(sim, maxDays, after: () {
    if (f.daySerial == lastDay) return false;
    lastDay = f.daySerial;
    final p = f.pressure[Commodity.steel];
    if (first == null && p != null && p.days > 0) first = f.daySerial;
    // The day before the mill is due: where its firm will put it.
    if (p != null &&
        p.days >= kFoundingPressureDays - 1 &&
        p.days < kFoundingPressureDays) {
      expected = sim.foundingSite(specOf('steelmill'));
    }
    return f.history.isNotEmpty;
  });
  return (
    firstPressureDay: first,
    foundedDay: f.history.isEmpty ? null : f.history.first.daySerial,
    expectedSite: expected,
  );
}

/// The site the firm [firm] runs, or fails the test.
String siteOf(CitySim sim, String firm) {
  final s = sim.siteOfFirm(firm);
  expect(s, isNotNull, reason: '$firm runs no plant');
  return s!;
}

void main() {
  // The headline: a sustained shortage founds a mill, after the pressure
  // delay, on a site the build ghost would accept, run by a new firm on the
  // template floor, served by the roads, and the player is told why.
  test('a sustained steel margin founds a Steel Mill after the delay', () {
    final sim = shortOfSteel();
    final r = runToFounding(sim);
    final f = sim.colonyEconomy.founding;
    expect(f.history, hasLength(1), reason: 'one founding');
    final founded = f.history.single;
    expect(founded.plantType, 'steelmill');
    expect(founded.good, anyOf(Commodity.steel, Commodity.tubes));
    expect(founded.firm, 'Aldine Corp');
    // The delay: the day the count began, plus the documented days.
    expect(r.firstPressureDay, isNotNull);
    expect(r.foundedDay! - r.firstPressureDay!,
        inInclusiveRange(kFoundingPressureDays - 1, kFoundingPressureDays));
    expect(founded.priceOverCost, greaterThan(1 / (1 - kFoundingMarginThreshold)));

    // The site: what the snap found the day before, which then passed the
    // build ghost's own predicate.
    final site = siteOf(sim, founded.firm);
    final expected = r.expectedSite!;
    final parcel = sim.layout.parcelById(site)!;
    expect(parcel.centroid.distanceTo(expected), lessThan(1.0));
    expect(sim.parcelBuildings[site]?.type, 'steelmill');
    expect(sim.parcelNetwork().lotServed(site), isTrue,
        reason: 'the roads serve it');

    // The firm: private, new, with its seed capital's working cash.
    final owner = sim.ownerOf(site);
    expect(owner.isState, isFalse);
    expect(owner.firmId, founded.firm);
    final book = sim.firmBookOf(site)!;
    expect(book.owner.firmId, founded.firm);
    expect(book.cash, greaterThan(0));

    // The floor: the template, seeded at the spec's flat rates.
    final rec = sim.factoryFloors[site]!;
    expect(rec.designed, isFalse);
    expect(jsonEncode(rec.blueprint.toJson()),
        jsonEncode(factoryTemplateFor('steelmill')!.toJson()));
    expect(jsonEncode(rec.rates.toJson()),
        jsonEncode(flatRatesOf(specOf('steelmill')).toJson()));

    // The notice.
    final notice = sim.colonyEconomy.notices
        .firstWhere((n) => n.contains('founded'));
    expect(
        notice,
        matches(RegExp(r'^Aldine Corp founded a Steel Mill — '
            r'(steel|tubes) was selling at \d+\.\d× its cost\.$')));
    // ignore: avoid_print
    print('scenario: pressure from day ${r.firstPressureDay}, founded on '
        'day ${r.foundedDay} at $site (${parcel.centroid.e.round()}, '
        '${parcel.centroid.n.round()}): $notice');
  });

  // At most one a cooldown, however dear the good stays.
  test('no second founding during the cooldown', () {
    final sim = shortOfSteel();
    runToFounding(sim);
    final f = sim.colonyEconomy.founding;
    expect(f.history, hasLength(1));
    expect(f.cooldownS, closeTo(kFoundingCooldownSec, 1e-6));
    // Steel still far short (four mills' worth wanted): the margin holds,
    // but the cooldown has a month to run.
    driveShortage(sim, 29, steel: 4 * kSteelWanted);
    expect(f.history, hasLength(1));
    expect(f.cooldownS, greaterThan(0));
  });

  test('no founding under communism', () {
    final sim = shortOfSteel(economy: Economy.communism);
    final r = runToFounding(sim, maxDays: 60);
    expect(r.foundedDay, isNull);
    expect(sim.colonyEconomy.founding.pressure, isEmpty);
    expect(sim.foundingRefusal, contains('Communism'));
  });

  // Socialism tolerates the odd venture: a third the rate, so its pressure
  // needs three times as long.
  test('socialism founds at a third of the rate', () {
    final sim = shortOfSteel(economy: Economy.socialism);
    final r = runToFounding(sim, maxDays: 50);
    expect(r.foundedDay, isNull,
        reason: 'a capitalist colony would have founded by now');
    final p = sim.colonyEconomy.founding.pressure[Commodity.steel]!;
    expect(p.days, greaterThan(0));
    expect(p.days, lessThan(kFoundingPressureDays));
  });

  test('no founding under Industrial Licensing', () {
    final sim = shortOfSteel()..laws.add(Law.industrialLicensing);
    final r = runToFounding(sim, maxDays: 60);
    expect(r.foundedDay, isNull);
    expect(sim.colonyEconomy.founding.pressure, isEmpty);
    // Repealed: the count starts afresh, from nothing.
    sim.laws.remove(Law.industrialLicensing);
    expect(sim.foundingRefusal, isNull);
  });

  // The control and secession gates: a Defiant or standing-off colony, an
  // independent one, or one under a no-demolition term sees no founding,
  // and the closed day drops whatever pressure had built.
  test('no founding in a colony on strike, gone, or under a ban', () {
    final sim = shortOfSteel();
    driveShortage(sim, 10);
    expect(sim.colonyEconomy.founding.pressure, isNotEmpty);
    for (final stage in [LoyaltyStage.defiant, LoyaltyStage.standoff]) {
      sim.loyalty.stage = stage;
      expect(sim.foundingRefusal, contains(stage.label));
      sim.entrepreneursCloseDay(kColonyDaySec);
      expect(sim.colonyEconomy.founding.pressure, isEmpty);
    }
    sim.loyalty.stage = LoyaltyStage.loyal;
    sim.loyalty.allegiance = Allegiance.independent;
    expect(sim.playerControl.allowed, isFalse);
    expect(sim.foundingRefusal, isNotNull);
    sim.loyalty.allegiance = Allegiance.colonial;
    expect(sim.foundingRefusal, isNull);
  });

  // A good that doesn't exist yet has no plant to found.
  test('no founding for an uninvented good', () {
    final sim = shortOfSteel();
    sim.colonyEconomy.tech = TechState(
        catalog: TechCatalog({
      ...kTechSeeds,
      Commodity.steel: const TechSeed(
        learningRate: 0.1,
        firstUnitPremium: 1,
        inventionDay: 10000,
        firstLotUnits: 1000,
        maturePrice: 50,
      ),
    }));
    expect(sim.unlocked(specOf('steelmill')), isFalse);
    final r = runToFounding(sim, maxDays: 60);
    expect(r.foundedDay, isNull);
    expect(sim.colonyEconomy.founding.pressure.containsKey(Commodity.steel),
        isFalse);
  });

  // Exit: a founded plant is an ordinary private plant, so one whose market
  // dries up (the consumers gone: on Mars, with no port, nothing it makes
  // sells) walks the firm policy's ladder and is offered to the player.
  test('a founded plant that loses money lays off, idles, closes, is offered',
      () {
    final sim = shortOfSteel();
    runToFounding(sim);
    final firm = sim.colonyEconomy.founding.history.single.firm;
    final site = siteOf(sim, firm);
    // No more foundings: this test is about the one plant.
    sim.laws.add(Law.industrialLicensing);
    sim.factoryFloors[site]!.blueprint.roster
      ..clear()
      ..[HandlerKind.onFoot] = 2;
    final walk = Walk();
    var t = 0.0;
    driveShortage(sim, 90, steel: 0, tubes: 0, cartOff: true, after: () {
      t += kEconTickS;
      final rec = sim.factoryFloors[site]!;
      if (walk.layoff == null &&
          rec.blueprint.roster[HandlerKind.onFoot] == 1) {
        walk.layoff = t;
      }
      final thr = sim.floorThrottleOf(site);
      if (walk.idle == null && thr == kIdleStationsThrottle) walk.idle = t;
      if (walk.close == null && thr == 0) walk.close = t;
      return walk.close != null;
    });
    expect(walk.layoff, isNotNull);
    expect(walk.idle, isNotNull);
    expect(walk.close, isNotNull);
    expect(walk.layoff!, lessThan(walk.idle!));
    expect(walk.idle!, lessThan(walk.close!));
    expect(sim.firmBookOf(site)!.health, FirmHealth.closed);
    final offer = sim.pendingFirmOffers.single;
    expect(offer.site, site);
    expect(offer.options,
        [ClosureOption.nationalise, ClosureOption.sellToNewFirm]);
    expect(sim.resolveFirmOffer(site, ClosureOption.sellToNewFirm), isTrue);
    expect(sim.ownerOf(site).firmId, isNot(firm));
  });

  // Same colony, same shortage: the same firm founds the same plant on the
  // same day on the same lot.
  test('foundings are deterministic', () {
    final a = shortOfSteel(), b = shortOfSteel();
    runToFounding(a);
    runToFounding(b);
    final fa = a.colonyEconomy.founding, fb = b.colonyEconomy.founding;
    expect(fa.history, hasLength(1));
    expect(jsonEncode(fa.toJsonOrNull()), jsonEncode(fb.toJsonOrNull()));
    final firm = fa.history.single.firm;
    expect(siteOf(a, firm), siteOf(b, firm));
  });

  // Saved mid-pressure and loaded, a colony founds exactly as it would have.
  test('the founding state saves and loads', () {
    final a = shortOfSteel();
    driveShortage(a, 15);
    final f = a.colonyEconomy.founding;
    expect(f.pressure[Commodity.steel]!.days, greaterThan(0));
    final json = a.toJson();
    expect(json['founding'], isNotNull);
    final b = reload(json);
    expect(jsonEncode(b.colonyEconomy.founding.toJsonOrNull()),
        jsonEncode(f.toJsonOrNull()));
    runToFounding(a);
    runToFounding(b);
    // The same firm founds the same plant on the same day. Not at the same
    // price: a plantless colony saves no market (`ColonyEconomy.hasState`),
    // so the loaded one's steel price re-seeded at the cost solve's, lower
    // than the climbed one but still over the threshold.
    final fb = b.colonyEconomy.founding.history.single;
    final fa = f.history.single;
    expect([fb.firm, fb.plantType, fb.daySerial],
        [fa.firm, fa.plantType, fa.daySerial]);
    expect(fb.priceOverCost, greaterThan(1 / (1 - kFoundingMarginThreshold)));
    // After the founding: the cooldown and the counter survive a load.
    final c = reload(a.toJson());
    expect(c.colonyEconomy.founding.cooldownS, f.cooldownS);
    expect(c.colonyEconomy.founding.firms, 1);
    expect(c.colonyEconomy.founding.nextFirm(), 'Brightwater Corp');

    // An old save (no 'founding' key) loads fresh: no pressure, no firms.
    final old = Map<String, dynamic>.of(a.toJson())..remove('founding');
    final d = reload(old);
    expect(d.colonyEconomy.founding.isFresh, isTrue);
  });

  // The pure pieces.
  test('founder names, rates and expected sell-through', () {
    expect(founderName(1), 'Aldine Corp');
    expect(founderName(12), 'Larkspur Corp');
    expect(founderName(13), 'Aldine Corp 2');
    expect(foundingRate(EconomyKind.capitalism), 1);
    expect(foundingRate(EconomyKind.freeMarket), 1);
    expect(foundingRate(EconomyKind.socialism), kSocialistFoundingRate);
    expect(foundingRate(EconomyKind.communism), 0);
    // Demand the existing plants already meet leaves the entrant half.
    expect(
        expectedSellThrough(
            demandPerS: 2, supplyPerS: 2, added: 2, exportable: false),
        0.5);
    expect(
        expectedSellThrough(
            demandPerS: 0, supplyPerS: 0, added: 2, exportable: true),
        1);
  });
}
