// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Inter-colony trade and the one world market
/// (docs/plans/dynamic-markets.md phase 5): two colonies share one Earth
/// and one world clock, a shortage in one pulls goods from the other at
/// freight, ports and launch capacity gate it, old saves merge their
/// per-colony worlds, and it is all deterministic.
library;

import 'dart:convert';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/persistence/game_state_codec.dart';
import 'package:acro_space_simulator/application/ports/world_repositories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/city_trade.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/colony_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/inter_colony_trade.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/markets.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/transport_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/world_economy.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory_integration/factory_colony_fixture.dart';

/// One tick, as the colony screens drive it.
const double kTickS = 0.5;

/// A relaxed starter colony [id] on [body] (its starter kit has a working
/// spaceport), its people pinned at [population].
CitySim colony(String id, String body, {double population = 300}) =>
    CityStarterKit.found(
        bodies: fixtureBodies(),
        config: CityConfig(bodyId: body),
        start: CityStart.relaxed,
        id: id,
      )
      ..hostility = 0
      ..pinPopulation = true
      ..population = population
      ..infinitePower = true;

/// Runs [cities] side by side for [days] economy days, a tick each in list
/// order. [granary] is held full of food, its top-up booked as the supply a
/// farm district would make, plus a steady surplus flow (12 units/s against
/// its people's 6): a colony that grows more than it eats.
void runWorld(
  List<CitySim> cities,
  double days, {
  Map<String, double> population = const {},
  CitySim? granary,
}) {
  final ticks = (days * kColonyDaySec / kTickS).round();
  for (var i = 0; i < ticks; i++) {
    for (final c in cities) {
      c.population = population[c.id] ?? 300;
      if (identical(c, granary)) {
        final e = c.colonyEconomy;
        final top = c.stockCap - c.stockOf(Commodity.food);
        if (top > 0) e.addFlow(Commodity.food, top / kTickS, kTickS);
        e.addFlow(Commodity.food, 12, kTickS);
        c.stock[Commodity.food] = c.stockCap;
      }
      c.advance(kTickS);
    }
  }
}

/// Two Martian colonies in one shared world: [a] a small town (100 people)
/// whose farm falls behind, [b] a granary.
({WorldEconomy world, CitySim a, CitySim b}) marsPair() {
  final world = WorldEconomy(shared: true);
  final a = colony('colony-a', 'mars', population: 100);
  final b = colony('colony-b', 'mars');
  a.joinWorld(world);
  b.joinWorld(world);
  return (world: world, a: a, b: b);
}

/// Tears down every spaceport [c] has: no port, no trade.
void closePort(CitySim c) {
  for (final (parcel, spec) in c.parcelBuiltLots().toList()) {
    if (spec.type == 'spaceport') c.clearParcel(parcel.id);
  }
  c.utils.removeWhere((_, s) => s.type == 'spaceport');
}

const Map<String, double> kPairPop = {'colony-a': 100, 'colony-b': 300};

/// A trade partner with no colony behind it: a bare economy and a stock.
class FakePartner implements TradePartner {
  FakePartner(
    this.colonyId,
    this.bodyId, {
    this.portOpen = true,
    this.launchCapacityKgPerDay = 1e9,
    this.stockCap = 1e9,
  });

  @override
  final String colonyId;
  @override
  final String bodyId;
  @override
  bool portOpen;
  @override
  double launchCapacityKgPerDay;
  @override
  double stockCap;
  @override
  final ColonyEconomy economy = ColonyEconomy();
  final Map<String, double> stock = {};

  @override
  double stockOf(String commodity) => stock[commodity] ?? 0;
  @override
  void addStock(String commodity, double units) =>
      stock[commodity] = stockOf(commodity) + units;

  /// Trades [good] at [price] with smoothed [demandPerS], holding [held].
  void market(
    String good,
    double price, {
    double demandPerS = 0,
    double held = 0,
  }) {
    economy.colonyMarket.goods[good] = GoodMarket(
      price: price,
      anchor: price,
      demandPerS: demandPerS,
    );
    stock[good] = held;
  }
}

void main() {
  test('two colonies share ONE world: one Earth, one clock', () {
    final p = marsPair();
    final ea = p.a.colonyEconomy, eb = p.b.colonyEconomy;
    expect(identical(ea.world, eb.world), isTrue);
    expect(identical(ea.tech.world, eb.tech.world), isTrue);
    runWorld([p.a, p.b], 5, population: kPairPop);
    // Each colony closed five days; the world stepped five, not ten.
    expect(p.world.tech.day, 5);
    expect(ea.tech.worldDay, 5);
    expect(identical(ea.earthMarket, eb.earthMarket), isTrue);
    expect(ea.earthMarket.goods, isNotEmpty);
    expect(p.world.pending, isEmpty, reason: 'the round closed');

    // A lone colony's private world steps on every close, as before.
    final lone = colony('lone', 'mars');
    runWorld([lone], 5);
    expect(lone.colonyEconomy.world.shared, isFalse);
    expect(lone.colonyEconomy.tech.worldDay, 5);
  });

  test('a member held back does not stop the world', () {
    final p = marsPair();
    // Only A runs: each of its closes after the first ends the round the
    // silent B never joined.
    runWorld([p.a], 4, population: kPairPop);
    expect(p.world.tech.day, 3);
    expect(p.world.pending.keys, ['colony-a']);
  });

  test('a shortage in A pulls food from B; prices meet within freight', () {
    final p = marsPair();
    runWorld([p.a, p.b], 30, population: kPairPop, granary: p.b);
    final ta = p.a.colonyEconomy.trade, tb = p.b.colonyEconomy.trade;
    final moved = ta.totalIn[Commodity.food] ?? 0;
    expect(moved, greaterThan(1000), reason: 'food was shipped');
    expect(tb.totalOut[Commodity.food], moved, reason: 'what left B landed');
    // Trade runs both ways where it pays: whatever A sells B lands there.
    for (final c in ta.totalOut.keys) {
      expect(tb.totalIn[c], ta.totalOut[c], reason: c);
    }
    expect(ta.lastImports.single.fromColony, 'colony-b');

    final pa = p.a.localPrices!.price(Commodity.food);
    final pb = p.b.localPrices!.price(Commodity.food);
    // Food is a kilogram a unit: freight between them is kSameBodyFreightPerKg.
    final landed = pb + kSameBodyFreightPerKg;
    expect(pa, greaterThan(pb), reason: 'A buys, B sells');
    // Arbitrage holds A at most one step's push (≤ 8% for life support)
    // past B's landed price.
    expect(pa, lessThan(landed * 1.1), reason: 'pa $pa landed $landed');
    // A's import ceiling is B's landed price, not Earth's (~$480 a kg).
    final ceiling = p.a.localPrices!.importCeiling[Commodity.food]!;
    expect(ceiling, lessThan(20));
    // B's exports are sales: its market's demand counts them, and its
    // smoothed export flow (what its reserve is measured without) is A's
    // daily order.
    final xps = tb.exportPerS[Commodity.food]!;
    expect(xps, greaterThan(0));
    expect(
      p.b.colonyEconomy.colonyMarket.goods[Commodity.food]!.demandPerS,
      greaterThan(xps),
    );
  });

  test('no working port, no trade', () {
    for (final shut in ['colony-a', 'colony-b']) {
      final p = marsPair();
      final closed = shut == 'colony-a' ? p.a : p.b;
      closePort(closed);
      expect(closed.hasSpaceport, isFalse);
      runWorld([p.a, p.b], 30, population: kPairPop, granary: p.b);
      expect(p.a.colonyEconomy.trade.totalIn, isEmpty, reason: shut);
      expect(p.b.colonyEconomy.trade.totalOut, isEmpty, reason: shut);
      // Nothing from B in A's band either: Earth's landed price is all.
      expect(
        p.a.localPrices!.importCeiling[Commodity.food]!,
        greaterThan(100),
        reason: shut,
      );
    }
  });

  test('launch capacity caps the volume', () {
    // Steel: 100 kg a unit. A wants (30 days × 1/s × 120 − 0) / 5 = 720
    // units; B holds 10,000 with no use for them.
    FakePartner pair(double capKg, String to) {
      final a = FakePartner('a', to, launchCapacityKgPerDay: capKg)
        ..market(Commodity.steel, 500, demandPerS: 1);
      return a;
    }

    final b = FakePartner('b', 'mars')
      ..market(Commodity.steel, 100, held: 10000);
    final transport = DeltaVTransportModel();
    final free = pair(1e9, 'mars');
    final legs = runImports(free, [b], transport);
    expect(legs.single.units, closeTo(720, 1e-9));

    final b2 = FakePartner('b', 'mars')
      ..market(Commodity.steel, 100, held: 10000);
    final capped = pair(5000, 'mars'); // 5 t a day: 50 units of steel
    final legs2 = runImports(capped, [b2], transport);
    expect(legs2.single.units, closeTo(50, 1e-9));
    expect(capped.economy.trade.portKgToday, closeTo(5000, 1e-6));
    expect(b2.economy.trade.portKgToday, closeTo(5000, 1e-6));
    // The day's capacity is spent: a second clearing moves nothing.
    expect(runImports(capped, [b2], transport), isEmpty);
    // The exporter's port caps it too, and a new day frees both.
    capped.economy.trade.closeDay(kColonyDaySec);
    b2.economy.trade.closeDay(kColonyDaySec);
    b2.launchCapacityKgPerDay = 1000;
    expect(runImports(capped, [b2], transport).single.units, closeTo(10, 1e-9));
  });

  test('same-body freight is cheap; between worlds it is Δv', () {
    final t = DeltaVTransportModel();
    expect(interColonyFreightPerKg(t, 'mars', 'mars'), kSameBodyFreightPerKg);
    final moonToMars = interColonyFreightPerKg(t, 'moon', 'mars');
    expect(moonToMars, t.perKg('moon', 'mars'));
    expect(moonToMars, greaterThan(kSameBodyFreightPerKg * 20));

    // The band quotes a same-body seller at its price + $2/kg, a Moon
    // seller at its price + the Δv freight.
    final a = FakePartner('a', 'mars')..market(Commodity.food, 50);
    final mars = FakePartner('m', 'mars')..market(Commodity.food, 10, held: 1);
    final moon = FakePartner('l', 'moon')..market(Commodity.food, 1, held: 1);
    expect(
      tradeBandFor(a, [mars], t).ceiling[Commodity.food],
      closeTo(10 + kSameBodyFreightPerKg, 1e-9),
    );
    expect(
      tradeBandFor(a, [moon], t).ceiling[Commodity.food],
      closeTo(1 + moonToMars, 1e-9),
    );
    // With both, the cheaper landed wins; with A's port shut, neither.
    expect(
      tradeBandFor(a, [moon, mars], t).ceiling[Commodity.food],
      closeTo(12, 1e-9),
    );
    a.portOpen = false;
    expect(tradeBandFor(a, [moon, mars], t).ceiling, isEmpty);
  });

  test('the cheapest landed source sells first; Earth beats a dear one', () {
    final t = DeltaVTransportModel();
    final a = FakePartner('a', 'mars')
      ..market(Commodity.steel, 900, demandPerS: 1);
    final near = FakePartner('z-near', 'mars')
      ..market(Commodity.steel, 100, held: 300);
    final far = FakePartner('b-far', 'moon')
      ..market(Commodity.steel, 100, held: 1e6);
    final legs = runImports(a, [far, near], t);
    expect(legs.first.fromColony, 'z-near', reason: 'landed $legs');
    expect(legs.first.units, 300);
    // Earth landed under the Moon's: the rest is left to Earth.
    final a2 = FakePartner('a', 'mars')
      ..market(Commodity.steel, 1e6, demandPerS: 1);
    final far2 = FakePartner('b-far', 'moon')
      ..market(Commodity.steel, 100, held: 1e6);
    final moonLanded = 100 + t.perKg('moon', 'mars') * 100; // 100 kg a unit
    expect(
      runImports(a2, [far2], t, earthLanded: {Commodity.steel: moonLanded - 1}),
      isEmpty,
    );
    expect(
      runImports(a2, [far2], t, earthLanded: {Commodity.steel: moonLanded + 1}),
      isNotEmpty,
    );
  });

  test('old saves merge their per-colony worlds: the most advanced wins', () {
    // Two lone colonies, as a pre-phase-5 game ran them: each its own
    // world, A six days on, B three.
    final a = colony('colony-a', 'mars');
    final b = colony('colony-b', 'moon');
    runWorld([a], 6);
    runWorld([b], 3);
    final aJson = jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>;
    final bJson = jsonDecode(jsonEncode(b.toJson())) as Map<String, dynamic>;
    expect((aJson['tech'] as Map)['day'], 6, reason: 'each saved its world');

    // An old save: its colonies carry their worlds, and there is no
    // 'worldEconomy' key. B first, so the rule is not "the first".
    const codec = GameStateCodec();
    Map<String, dynamic> save(CityRepository cities) =>
        jsonDecode(
              jsonEncode(
                codec.encode(
                  vessels: InMemoryVesselRepository(const []),
                  colonies: InMemoryColonyRepository(),
                  deposits: InMemoryDepositRepository(),
                  clock: SimulationClock(warpFactor: 1, fixedStep: 0.02),
                  cities: cities,
                ),
              ),
            )
            as Map<String, dynamic>;
    final old = save(InMemoryCityRepository())
      ..['cities'] = [bJson, aJson]
      ..remove('worldEconomy');
    CityRepository load(Map<String, dynamic> j) {
      final repo = InMemoryCityRepository();
      codec.decode(
        j,
        vessels: InMemoryVesselRepository(const []),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        clock: SimulationClock(warpFactor: 1, fixedStep: 0.02),
        cities: repo,
        bodies: fixtureBodies(),
      );
      return repo;
    }

    final repo = load(old);
    final world = repo.worldEconomy;
    expect(world.tech.day, 6);
    expect(world.members.keys, ['colony-a', 'colony-b']);
    for (final c in repo.all()) {
      expect(identical(c.colonyEconomy.world, world), isTrue);
    }
    expect(
      jsonEncode(world.earth.toJson()),
      jsonEncode(a.colonyEconomy.earthMarket.toJson()),
      reason: "A's Earth, the most advanced",
    );

    // Saved again, the world is written ONCE and the colonies carry none.
    final fresh = save(repo);
    expect((fresh['worldEconomy'] as Map)['day'], 6);
    for (final cj in (fresh['cities'] as List)) {
      final m = cj as Map<String, dynamic>;
      expect((m['tech'] as Map?)?['day'], isNull);
      expect((m['plantEconomy'] as Map?)?['earthMkt'], isNull);
    }
    final again = load(fresh);
    expect(jsonEncode(again.worldEconomy.toJson()), jsonEncode(world.toJson()));
  });

  test('trade state saves with the colony', () {
    final p = marsPair();
    runWorld([p.a, p.b], 30.5, population: kPairPop, granary: p.b);
    final json = p.a.toJson();
    expect(json['trade'], isNotNull);
    final loaded = CitySim.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      bodies: fixtureBodies(),
    );
    expect(
      jsonEncode(loaded.colonyEconomy.trade.toJsonOrNull()),
      jsonEncode(p.a.colonyEconomy.trade.toJsonOrNull()),
    );
    // A colony that never traded saves no trade key, as before.
    expect(colony('quiet', 'mars').toJson().containsKey('trade'), isFalse);
  });

  test('deterministic: two runs, the same world and the same trade', () {
    String run() {
      final p = marsPair();
      runWorld([p.a, p.b], 25, population: kPairPop, granary: p.b);
      return jsonEncode({
        'world': p.world.toJson(),
        'a': p.a.colonyEconomy.toJson(),
        'b': p.b.colonyEconomy.toJson(),
        'ta': p.a.colonyEconomy.trade.toJsonOrNull(),
        'tb': p.b.colonyEconomy.trade.toJsonOrNull(),
        'stock': [p.a.stock, p.b.stock],
      });
    }

    expect(run(), run());
  });
}
