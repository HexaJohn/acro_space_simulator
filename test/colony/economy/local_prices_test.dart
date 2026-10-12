// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/commodity_mass.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/earth_market.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/local_prices.dart';
import 'package:flutter_test/flutter_test.dart';

const _earthAir = {'N2': 0.78, 'O2': 0.21};
const _marsAir = {'CO2': 0.95, 'N2': 0.03};

MarketFacts _earth({int population = 500}) => MarketFacts(
    bodyId: 'earth', economy: EconomyKind.capitalism, atmosphere: _earthAir,
    population: population);

/// A Martian colony. Ice cap ≈ biome iceCap's 1.4 water; dry equator ≈
/// desert's 0.5. Sunlight at 1.52 AU is ~43% of Earth's.
MarketFacts _mars({
  double waterMult = 1,
  int population = 100,
  EconomyKind economy = EconomyKind.capitalism,
  Map<String, double> stock = const {},
  Map<String, double> demand = const {},
  Map<String, double> supply = const {},
}) =>
    MarketFacts(
        bodyId: 'mars', economy: economy, atmosphere: _marsAir,
        waterMult: waterMult, solarFactor: 0.43, population: population,
        stock: stock, demandPerS: demand, supplyPerS: supply);

MarketFacts _moon({int population = 100}) => MarketFacts(
    bodyId: 'moon', economy: EconomyKind.capitalism, waterMult: 0.6,
    population: population);

/// Local, derived prices (docs/plans/factory-floors.md §3). These pin the
/// answer to the user's question that shaped the model — oxygen is cheap on
/// Earth, dearer on Mars, dearest on a dry Martian plain, and dearest of all
/// shipped from Earth — plus the solver's own guarantees.
void main() {
  /// The headline ordering: Earth ≪ Mars at the ice cap < Mars on a dry
  /// equator ≪ oxygen landed from Earth. Water is the lever: electrolysis
  /// oxygen is mostly water and labour, and the ice makes the water cheap.
  test('oxygen: Earth << Mars ice cap < Mars dry equator << import', () {
    final earth = solveLocalPrices(_earth()).price(Commodity.oxygen);
    final ice = solveLocalMarket(_mars(waterMult: 1.4));
    final dry = solveLocalMarket(_mars(waterMult: 0.5));
    final o2Ice = ice.book.price(Commodity.oxygen);
    final o2Dry = dry.book.price(Commodity.oxygen);
    final landed = ice.book.importCeiling[Commodity.oxygen]!;

    expect(earth * 10, lessThan(o2Ice));
    expect(o2Ice, lessThan(o2Dry));
    expect(o2Dry * 5, lessThan(landed));
    // The plan's ballparks (credits ≈ $ per kg; one oxygen unit is 1 kg).
    expect(earth, closeTo(0.2, 0.05));
    expect(o2Ice, inInclusiveRange(3, 25));
    expect(o2Dry, inInclusiveRange(15, 80));
    expect(landed, inInclusiveRange(150, 5000));
  });

  /// Mars always breathes its own: from a dry desert (biome water 0.5) to
  /// the ice cap and beyond, and whatever the economy, local oxygen beats
  /// the import ceiling.
  test('Mars never imports its oxygen', () {
    for (final w in const [0.5, 0.6, 1.0, 1.4, 1.8]) {
      for (final e in EconomyKind.values) {
        final m = solveLocalMarket(_mars(waterMult: w, economy: e));
        expect(m.sourceOf[Commodity.oxygen], isNot(kSourceImport),
            reason: 'waterMult $w, $e');
        expect(m.book.price(Commodity.oxygen),
            lessThan(m.book.importCeiling[Commodity.oxygen]!));
      }
    }
  });

  /// An O₂ harvester needs oxygen-bearing air in proportion to its partial
  /// pressure: none on the airless Moon (electrolysis it is), ~1% of the
  /// Earth nameplate from Mars' thin CO₂, so electrolysis wins there too.
  test('airless Moon makes oxygen by electrolysis, not the harvester', () {
    final moon = solveLocalMarket(_moon());
    expect(moon.sourceOf[Commodity.oxygen], 'electrolysis');
    final mars = solveLocalMarket(_mars());
    expect(mars.sourceOf[Commodity.oxygen], 'electrolysis');
    // Given a thick enough oxygen sky the harvester is the cheaper recipe:
    // an Earth-air colony off Earth (no world market next door).
    final terraformed = solveLocalMarket(MarketFacts(
        bodyId: 'mars', economy: EconomyKind.capitalism,
        atmosphere: _earthAir, surfacePressureKPa: 101.325, population: 100));
    expect(terraformed.sourceOf[Commodity.oxygen], 'o2harvester');
  });

  /// High value per kg: electronics on a young Mars colony (no plant
  /// unlocked yet) sit exactly at the import ceiling; once the colony can
  /// run an electronics plant (and the data centre it needs), the price
  /// falls below it.
  test('electronics: import ceiling until a local plant exists, then lower',
      () {
    final young = solveLocalMarket(_mars(population: 100));
    final ceiling = young.book.importCeiling[Commodity.electronics]!;
    expect(young.sourceOf[Commodity.electronics], kSourceImport);
    expect(young.book.price(Commodity.electronics), ceiling);
    expect(young.localCost[Commodity.electronics], isNull);

    final grown = solveLocalMarket(_mars(population: 500));
    expect(grown.sourceOf[Commodity.electronics], 'electronics');
    expect(grown.book.price(Commodity.electronics), lessThan(ceiling * 0.5));
    expect(grown.localCost[Commodity.electronics]!,
        lessThan(grown.book.price(Commodity.electronics) + 1e-9),
        reason: 'priced at or above cost (the export floor may lift it)');
  });

  /// Low value per kg goods are always made off Earth once a recipe exists:
  /// water, food, steel on Mars are far below their landed-from-Earth cost.
  test('heavy cheap goods are made locally off Earth', () {
    final m = solveLocalMarket(_mars(population: 500));
    for (final c in const [
      Commodity.water, Commodity.food, Commodity.steel, Commodity.ore,
    ]) {
      expect(m.sourceOf[c], isNot(kSourceImport), reason: c);
      expect(m.book.price(c) * 10, lessThan(m.book.importCeiling[c]!),
          reason: c);
    }
  });

  /// The wage ↔ life-support fixed point converges, and the solve is
  /// deterministic: two solves give identical books, and the solved wage is
  /// exactly the basket at the solved prices (it IS a fixed point).
  test('fixed point converges, is deterministic and self-consistent', () {
    for (final f in [_earth(), _mars(waterMult: 0.5), _moon()]) {
      final a = solveLocalMarket(f);
      final b = solveLocalMarket(f);
      expect(a.converged, isTrue, reason: f.bodyId);
      expect(a.book.prices, b.book.prices);
      expect(a.book.wagePerWorkerS, b.book.wagePerWorkerS);
      expect(a.book.powerPerKJ, b.book.powerPerKJ);

      final p = a.book.prices;
      var perDay = kHousingPerPersonDay +
          kWaterKgPerPersonDay * p[Commodity.water]! /
              kgPerUnit(Commodity.water) +
          kFoodKgPerPersonDay * p[Commodity.food]! / kgPerUnit(Commodity.food);
      if (f.bodyId != 'earth') {
        perDay += kO2KgPerPersonDay * p[Commodity.oxygen]! /
            kgPerUnit(Commodity.oxygen);
      }
      final expected =
          perDay / kColonyDaySec * kPeoplePerWorker * wageMarkup(f.economy);
      expect(a.book.wagePerWorkerS, closeTo(expected, expected * 1e-5));
    }
  });

  /// A site too poor to feed its own workers (a volcano's 0.3 water and 0.2
  /// food): life support would cost more than the labour it keeps alive,
  /// so the unclamped wage loop has no finite fixed point. The import
  /// ceiling bounds it — the solve still converges, deterministically, to
  /// prices pinned at the ceiling, which is the honest answer: such a
  /// colony lives on imports. (Integration tunes where that line falls.)
  test('a site that cannot feed its workers pins at the ceiling, converged',
      () {
    final f = MarketFacts(
        bodyId: 'mars', economy: EconomyKind.freeMarket,
        atmosphere: _marsAir, waterMult: 0.3, foodMult: 0.2,
        solarFactor: 0.43, population: 100);
    final m = solveLocalMarket(f);
    expect(m.converged, isTrue);
    expect(m.book.price(Commodity.oxygen),
        m.book.importCeiling[Commodity.oxygen]);
    expect(m.book.wagePerWorkerS.isFinite, isTrue);
  });

  /// Too few iterations reports non-convergence rather than pretending.
  test('an iteration cap too small reports not converged', () {
    final m = solveLocalMarket(_mars(waterMult: 0.5), maxIterations: 2);
    expect(m.converged, isFalse);
    expect(m.iterations, 2);
  });

  /// Every price sits between its export floor and import ceiling, across
  /// worlds, scarcity states and a second colony as a market.
  test('floor <= price <= ceiling everywhere', () {
    final mars = solveLocalPrices(_mars(population: 500));
    final cases = [
      _earth(),
      _mars(),
      _mars(waterMult: 0.4, stock: {Commodity.water: 0},
          demand: {Commodity.water: 5}, supply: {Commodity.water: 1}),
      _mars(population: 500, stock: {Commodity.steel: 1e6},
          supply: {Commodity.steel: 9}, demand: {Commodity.steel: 1}),
      _moon(population: 1000),
    ];
    for (final f in cases) {
      final b = solveLocalPrices(f, otherMarkets: {'mars': mars});
      for (final c in b.prices.keys) {
        final p = b.prices[c]!;
        final lo = b.exportFloor[c] ?? 0;
        final hi = b.importCeiling[c] ?? double.infinity;
        expect(lo, lessThanOrEqualTo(hi), reason: '${f.bodyId} $c');
        expect(p, greaterThanOrEqualTo(lo - 1e-9), reason: '${f.bodyId} $c');
        expect(p, lessThanOrEqualTo(hi + 1e-9), reason: '${f.bodyId} $c');
      }
    }
  });

  /// On Earth the colony trades at the world market: floor and ceiling are
  /// both the Earth price.
  test('an Earth colony trades at Earth prices', () {
    final b = solveLocalPrices(_earth());
    for (final c in const [
      Commodity.oxygen, Commodity.steel, Commodity.electronics,
    ]) {
      expect(b.price(c), closeTo(earthPrice(c), 1e-9), reason: c);
    }
  });

  /// Scarcity moves price within the bounds: a drained stock costs more
  /// than a neutral one, a glut less.
  test('scarcity raises a drained good and lowers a glut', () {
    final neutral = solveLocalPrices(_mars()).price(Commodity.water);
    final short = solveLocalPrices(_mars(stock: {Commodity.water: 10},
        demand: {Commodity.water: 2}, supply: {Commodity.water: 1}));
    final glut = solveLocalPrices(_mars(stock: {Commodity.water: 1e5},
        demand: {Commodity.water: 1}, supply: {Commodity.water: 3}));
    expect(short.price(Commodity.water), greaterThan(neutral));
    expect(glut.price(Commodity.water), lessThan(neutral));
  });

  /// Another colony is a source too: tubes on a young lunar colony (no
  /// steel mill yet) are cheaper bought from a Martian colony that makes
  /// them than lifted out of Earth's well.
  test('another colony can undercut Earth as an import source', () {
    final mars = solveLocalPrices(_mars(population: 500));
    final alone = solveLocalPrices(_moon());
    final trading = solveLocalPrices(_moon(), otherMarkets: {'mars': mars});
    expect(trading.importCeiling[Commodity.tubes]!,
        lessThan(alone.importCeiling[Commodity.tubes]!));
  });
}
