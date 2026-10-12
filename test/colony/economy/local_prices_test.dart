// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/commodity_mass.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/earth_market.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/local_prices.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

// ---- fixtures: REAL colonies ------------------------------------------------
//
// Every site below is a real `CitySim` founded on a real body and biome, and
// its MarketFacts are read off the sim the way the aggregate will build them:
// `biomeMult` for the yields (the real `biomeFx` table), `powerFactor` per
// power type, `o2Harvestable`, the derived sky. No hand-picked multipliers.

final List<CelestialBody> _bodies =
    RealSolarSystem.build().all.where((b) => !b.isStar).toList();
final Map<String, CitySim> _sims = {};

CitySim _sim(String body, Biome biome) =>
    _sims['$body/${biome.name}'] ??= CitySim.found(
        CityConfig(bodyId: body, biome: biome, gridSize: 8),
        bodies: _bodies);

const Map<AtmosphereGas, String> _formula = {
  AtmosphereGas.nitrogen: 'N2',
  AtmosphereGas.oxygen: 'O2',
  AtmosphereGas.carbonDioxide: 'CO2',
  AtmosphereGas.hydrogen: 'H2',
  AtmosphereGas.helium: 'He',
  AtmosphereGas.methane: 'CH4',
  AtmosphereGas.argon: 'Ar',
  AtmosphereGas.water: 'H2O',
};

const List<String> _powerTypes = [
  'solar', 'solar-big', 'solarthermal', 'wind', 'gas', 'reactor', 'fusion',
];

MarketFacts _site(
  String body,
  Biome biome, {
  EconomyKind economy = EconomyKind.capitalism,
  int population = 100,
  Map<String, double> stock = const {},
  Map<String, double> demand = const {},
  Map<String, double> supply = const {},
  bool canExport = false,
}) {
  final s = _sim(body, biome);
  final sky = s.sky;
  return MarketFacts(
    bodyId: body,
    economy: economy,
    solarFactor: s.solarFactor,
    waterMult: s.biomeMult(Commodity.water),
    oreMult: s.biomeMult(Commodity.ore),
    foodMult: s.biomeMult(Commodity.food),
    atmosphere: {
      for (final e in s.body.composition?.fractions.entries ??
          const <MapEntry<AtmosphereGas, double>>[])
        _formula[e.key]!: e.value,
    },
    surfacePressureKPa: sky.pressureAtm * 101.325,
    airDensity: sky.airDensity,
    o2Harvestable: s.o2Harvestable,
    powerFactors: {for (final t in _powerTypes) t: s.powerFactor(t)},
    population: population,
    stock: stock,
    demandPerS: demand,
    supplyPerS: supply,
    canExport: canExport,
  );
}

MarketFacts _earth({int population = 500}) =>
    _site('earth', Biome.grassland, population: population);

MarketFacts _mars(
  Biome biome, {
  int population = 100,
  EconomyKind economy = EconomyKind.capitalism,
  Map<String, double> stock = const {},
  Map<String, double> demand = const {},
  Map<String, double> supply = const {},
  bool canExport = false,
}) =>
    _site('mars', biome,
        population: population, economy: economy, stock: stock,
        demand: demand, supply: supply, canExport: canExport);

MarketFacts _moon(Biome biome, {int population = 100}) =>
    _site('moon', biome, population: population);

/// The real biomes a Martian colony can stand on (frozen climate: ice,
/// tundra, dust, rock, highlands, old lava) and a lunar one (regolith,
/// polar ice, highlands). The volcano biome is the one exception, below.
const List<Biome> _marsBiomes = [
  Biome.iceCap, Biome.tundra, Biome.desert, Biome.barren, Biome.mountains,
  Biome.volcanic,
];
const List<Biome> _moonBiomes = [Biome.barren, Biome.iceCap, Biome.mountains];

/// Local, derived prices (docs/plans/factory-floors.md §3). These pin the
/// answer to the user's question that shaped the model — oxygen is cheap on
/// Earth, dearer on Mars, dearest on a dry Martian plain, and dearest of all
/// shipped from Earth — plus the solver's own guarantees.
void main() {
  /// The fixtures really are the sim's table: iceCap water 1.4 / food 0.5,
  /// desert 0.5 / 0.5, barren 0.6 / 0.3 — and the real Mars/Moon sky.
  test('fixtures carry the real biome table and sky', () {
    final ice = _mars(Biome.iceCap);
    expect(ice.waterMult, 1.4);
    expect(ice.foodMult, 0.5);
    final dry = _mars(Biome.desert);
    expect(dry.waterMult, 0.5);
    expect(dry.foodMult, 0.5);
    final moon = _moon(Biome.barren);
    expect(moon.waterMult, 0.6);
    expect(moon.foodMult, 0.3);
    expect(moon.atmosphere, isEmpty);
    expect(ice.o2Harvestable, isFalse);
    expect(ice.solarFactor, closeTo(0.43, 0.01));
  });

  /// The headline ordering with REAL inputs: Earth ≪ Mars at the ice cap <
  /// a dry Martian plain and the lunar regolith ≪ oxygen landed from Earth.
  /// Water is the lever: electrolysis oxygen is mostly water and labour,
  /// and the ice makes the water cheap.
  test('oxygen: Earth << Mars ice cap < Mars desert, Moon barren << import',
      () {
    final earth = solveLocalPrices(_earth()).price(Commodity.oxygen);
    final ice = solveLocalMarket(_mars(Biome.iceCap));
    final dry = solveLocalMarket(_mars(Biome.desert));
    final moon = solveLocalMarket(_moon(Biome.barren));
    final o2Ice = ice.book.price(Commodity.oxygen);
    final o2Dry = dry.book.price(Commodity.oxygen);
    final o2Moon = moon.book.price(Commodity.oxygen);
    final landed = ice.book.importCeiling[Commodity.oxygen]!;

    for (final m in [ice, dry, moon]) {
      expect(m.sourceOf[Commodity.oxygen], 'electrolysis');
      expect(m.converged, isTrue);
    }
    expect(earth * 10, lessThan(o2Ice));
    expect(o2Ice, lessThan(o2Dry));
    expect(o2Ice, lessThan(o2Moon));
    expect(o2Dry * 5, lessThan(landed));
    expect(o2Moon * 5,
        lessThan(moon.book.importCeiling[Commodity.oxygen]!));
    // The plan's ballparks (credits ≈ $ per kg; one oxygen unit is 1 kg).
    expect(earth, closeTo(0.2, 0.05));
    expect(o2Ice, inInclusiveRange(3, 25));
    expect(o2Dry, inInclusiveRange(15, 80));
    expect(o2Moon, inInclusiveRange(15, 80));
    expect(landed, inInclusiveRange(150, 5000));
  });

  /// Mars and the Moon always breathe and eat their own: on every real
  /// biome they have, at both colony sizes, whatever the economy, local
  /// oxygen and food beat the import ceiling and the solve converges —
  /// labour's share of the subsistence basket stays below one.
  test('Mars and the Moon never import oxygen or food on a real biome', () {
    final sites = [
      for (final b in _marsBiomes) ('mars', b),
      for (final b in _moonBiomes) ('moon', b),
    ];
    for (final (body, biome) in sites) {
      for (final pop in const [100, 500]) {
        for (final e in EconomyKind.values) {
          final m = solveLocalMarket(
              _site(body, biome, economy: e, population: pop));
          final why = '$body ${biome.name} pop $pop ${e.name}';
          expect(m.converged, isTrue, reason: why);
          for (final c in const [Commodity.oxygen, Commodity.food]) {
            expect(m.sourceOf[c], isNot(kSourceImport), reason: '$why $c');
            expect(m.book.price(c), lessThan(m.book.importCeiling[c]! * 0.2),
                reason: '$why $c');
          }
        }
      }
    }
  });

  /// The one real biome that cannot feed its workers: a volcano's 0.3
  /// water and 0.2 food. Making a colonist's day of water, food and oxygen
  /// there takes more worker-seconds than a day holds, so the unclamped
  /// wage loop has no finite fixed point. The import ceiling bounds it —
  /// the solve still converges, deterministically, to prices pinned at the
  /// ceiling, which is the honest answer: such a colony lives on imports.
  test('a Martian volcano cannot feed its workers: pinned at the ceiling',
      () {
    for (final e in EconomyKind.values) {
      final m = solveLocalMarket(_mars(Biome.volcano, economy: e));
      expect(m.converged, isTrue);
      expect(m.sourceOf[Commodity.oxygen], kSourceImport);
      expect(m.book.price(Commodity.oxygen),
          m.book.importCeiling[Commodity.oxygen]);
      expect(m.book.wagePerWorkerS.isFinite, isTrue);
    }
  });

  /// The O₂ harvester mirrors `CitySim.o2Harvestable` exactly: no credit
  /// for CO₂ (no MOXIE), no scaling by partial pressure — gated on, full
  /// nameplate, or off.
  test('O2 harvester: gated like the sim, full nameplate or nothing', () {
    expect(solveLocalMarket(_moon(Biome.barren)).sourceOf[Commodity.oxygen],
        'electrolysis');
    expect(solveLocalMarket(_mars(Biome.iceCap)).sourceOf[Commodity.oxygen],
        'electrolysis');

    // Venus: 92 bar of CO₂ and no oxygen. The sim's harvester draws
    // nothing there, and neither may the market's.
    final venus = _site('venus', Biome.volcanic);
    expect(venus.o2Harvestable, isFalse);
    expect(solveLocalMarket(venus).sourceOf[Commodity.oxygen],
        isNot('o2harvester'));
    // The same without the aggregate's flag: the mirrored rule decides.
    final venusRaw = MarketFacts(
        bodyId: 'venus', economy: EconomyKind.capitalism,
        atmosphere: const {'CO2': 0.965, 'N2': 0.035}, population: 100);
    expect(solveLocalMarket(venusRaw).sourceOf[Commodity.oxygen],
        isNot('o2harvester'));

    // A thin but harvestable sky (5% O₂, 0.06 kg/m³): the sim runs the
    // harvester at full nameplate, so it is the cheapest oxygen.
    final thin = MarketFacts(
        bodyId: 'mars', economy: EconomyKind.capitalism,
        atmosphere: const {'O2': 0.05, 'CO2': 0.95},
        surfacePressureKPa: 5, airDensity: 0.05, population: 100);
    final m = solveLocalMarket(thin);
    expect(m.sourceOf[Commodity.oxygen], 'o2harvester');
    // Exactly the nameplate: its running cost over its full 2.0/s.
    final harvester = kUtilCatalog.firstWhere((s) => s.type == 'o2harvester');
    final w = m.book.wagePerWorkerS;
    final power = m.book.powerPerKJ * kKjPerPowerUnitS;
    final capex = harvester.buildCost * m.book.price(Commodity.ore) /
        (kCapitalRecoveryYears * kGameYearSec);
    final unit = (harvester.jobs * w + harvester.powerDraw * power + capex) /
        harvester.outputs[Commodity.oxygen]!;
    expect(m.localCost[Commodity.oxygen], closeTo(unit, unit * 1e-6));

    // Earth-thick oxygen air the aggregate says is NOT harvestable stays
    // unharvested: the flag is the one source of truth.
    final flagged = MarketFacts(
        bodyId: 'mars', economy: EconomyKind.capitalism,
        atmosphere: const {'N2': 0.78, 'O2': 0.21}, surfacePressureKPa: 5,
        airDensity: 1, o2Harvestable: false, population: 100);
    expect(solveLocalMarket(flagged).sourceOf[Commodity.oxygen],
        isNot('o2harvester'));
  });

  /// Power mirrors `CitySim.powerFactor`: only the 'solar' farm scales
  /// with sunlight (and its biome and nuclear winter); the solar array and
  /// solar thermal run at nameplate; wind scales with air density, 0..3.
  test('power factor mirrors the sim, and the aggregate map wins', () {
    CityBuildingSpec spec(String type) =>
        kUtilCatalog.firstWhere((s) => s.type == type);
    double powerPrice(MarketFacts f, String type) =>
        solveLocalPrices(f, recipes: [spec(type)]).powerPerKJ;
    MarketFacts facts({
      double solar = 1,
      double? airDensity,
      Map<String, double> factors = const {},
    }) =>
        MarketFacts(
            bodyId: 'mars', economy: EconomyKind.capitalism,
            atmosphere: const {'CO2': 0.95, 'N2': 0.03}, solarFactor: solar,
            airDensity: airDensity, powerFactors: factors, population: 500);

    // Solar array and solar thermal: nameplate, whatever the sun.
    for (final t in const ['solar-big', 'solarthermal']) {
      expect(powerPrice(facts(solar: 0.43), t),
          closeTo(powerPrice(facts(solar: 1), t), 1e-15), reason: t);
    }
    // The solar farm: inversely with sunlight.
    expect(powerPrice(facts(solar: 0.5), 'solar'),
        closeTo(2 * powerPrice(facts(solar: 1), 'solar'), 1e-12));
    // Wind: with air density, clamped at 3.
    expect(powerPrice(facts(airDensity: 1), 'wind'),
        closeTo(2 * powerPrice(facts(airDensity: 2), 'wind'), 1e-12));
    expect(powerPrice(facts(airDensity: 50), 'wind'),
        closeTo(powerPrice(facts(airDensity: 3), 'wind'), 1e-15));
    // The aggregate's per-type factor (biome, nuclear winter) overrides.
    expect(powerPrice(facts(factors: {'solar': 0.25}), 'solar'),
        closeTo(4 * powerPrice(facts(), 'solar'), 1e-12));
    // A real dusty iceCap colony: the sim's own factor, biome included.
    final ice = _mars(Biome.iceCap);
    expect(ice.powerFactors['solar'],
        closeTo(ice.solarFactor * 0.6, 1e-12));
  });

  /// No spaceport, no export floor: a colony that cannot ship to Earth
  /// cannot get Earth's price for anything. With one, the floor is the
  /// Earth price less the trip.
  test('export floor only for a colony that can export', () {
    final shut = solveLocalPrices(_mars(Biome.iceCap, population: 500));
    for (final e in shut.exportFloor.entries) {
      expect(e.value, 0, reason: e.key);
    }
    final open = solveLocalPrices(
        _mars(Biome.iceCap, population: 500, canExport: true));
    expect(open.exportFloor[Commodity.electronics]!, greaterThan(0));
    for (final c in open.prices.keys) {
      expect(open.prices[c]!,
          greaterThanOrEqualTo((open.exportFloor[c] ?? 0) - 1e-9),
          reason: c);
    }
    // An Earth colony sells on its own world, spaceport or not.
    final earth = solveLocalPrices(_earth());
    expect(earth.exportFloor[Commodity.oxygen], earthPrice(Commodity.oxygen));
  });

  /// High value per kg: electronics on a young Mars colony (no plant
  /// unlocked yet) sit exactly at the import ceiling; once the colony can
  /// run an electronics plant (and the data centre it needs), the price
  /// falls below it.
  test('electronics: import ceiling until a local plant exists, then lower',
      () {
    final young = solveLocalMarket(_mars(Biome.iceCap, population: 100));
    final ceiling = young.book.importCeiling[Commodity.electronics]!;
    expect(young.sourceOf[Commodity.electronics], kSourceImport);
    expect(young.book.price(Commodity.electronics), ceiling);
    expect(young.localCost[Commodity.electronics], isNull);

    final grown = solveLocalMarket(_mars(Biome.iceCap, population: 500));
    expect(grown.sourceOf[Commodity.electronics], 'electronics');
    expect(grown.book.price(Commodity.electronics), lessThan(ceiling * 0.5));
    expect(grown.localCost[Commodity.electronics]!,
        lessThan(grown.book.price(Commodity.electronics) + 1e-9));
  });

  /// Low value per kg goods are always made off Earth once a recipe exists:
  /// water, food, steel on Mars are far below their landed-from-Earth cost.
  test('heavy cheap goods are made locally off Earth', () {
    for (final b in const [Biome.iceCap, Biome.desert, Biome.barren]) {
      final m = solveLocalMarket(_mars(b, population: 500));
      for (final c in const [
        Commodity.water, Commodity.food, Commodity.steel, Commodity.ore,
      ]) {
        expect(m.sourceOf[c], isNot(kSourceImport), reason: '${b.name} $c');
        expect(m.book.price(c) * 10, lessThan(m.book.importCeiling[c]!),
            reason: '${b.name} $c');
      }
    }
  });

  /// The wage ↔ life-support fixed point converges, and the solve is
  /// deterministic: two solves give identical books, and the solved wage is
  /// exactly the subsistence basket plus marked-up housing at the solved
  /// prices (it IS a fixed point).
  test('fixed point converges, is deterministic and self-consistent', () {
    for (final f in [
      _earth(), _mars(Biome.desert), _mars(Biome.barren), _moon(Biome.barren),
    ]) {
      final a = solveLocalMarket(f);
      final b = solveLocalMarket(f);
      expect(a.converged, isTrue, reason: f.bodyId);
      expect(a.book.prices, b.book.prices);
      expect(a.book.wagePerWorkerS, b.book.wagePerWorkerS);
      expect(a.book.powerPerKJ, b.book.powerPerKJ);

      final p = a.book.prices;
      var basket = kWaterKgPerPersonDay * p[Commodity.water]! /
              kgPerUnit(Commodity.water) +
          kFoodKgPerPersonDay * p[Commodity.food]! / kgPerUnit(Commodity.food);
      if (f.bodyId != 'earth') {
        basket += kO2KgPerPersonDay * p[Commodity.oxygen]! /
            kgPerUnit(Commodity.oxygen);
      }
      final expected = (basket * kPeoplePerWorker +
              kHousingPerPersonDay * wageMarkup(f.economy)) /
          kColonyDaySec;
      expect(a.book.wagePerWorkerS, closeTo(expected, expected * 1e-5));
    }
  });

  /// Too few iterations reports non-convergence rather than pretending.
  test('an iteration cap too small reports not converged', () {
    final m = solveLocalMarket(_mars(Biome.desert), maxIterations: 2);
    expect(m.converged, isFalse);
    expect(m.iterations, 2);
  });

  /// Every price sits between its export floor and import ceiling, across
  /// worlds, scarcity states and a second colony as a market.
  test('floor <= price <= ceiling everywhere', () {
    final mars = solveLocalPrices(_mars(Biome.iceCap, population: 500));
    final cases = [
      _earth(),
      _mars(Biome.iceCap),
      _mars(Biome.iceCap, canExport: true, population: 500),
      _mars(Biome.barren, stock: {Commodity.water: 0},
          demand: {Commodity.water: 5}, supply: {Commodity.water: 1}),
      _mars(Biome.desert, population: 500, stock: {Commodity.steel: 1e6},
          supply: {Commodity.steel: 9}, demand: {Commodity.steel: 1},
          canExport: true),
      _mars(Biome.volcano),
      _moon(Biome.barren, population: 1000),
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
    final neutral =
        solveLocalPrices(_mars(Biome.iceCap)).price(Commodity.water);
    final short = solveLocalPrices(_mars(Biome.iceCap,
        stock: {Commodity.water: 10}, demand: {Commodity.water: 2},
        supply: {Commodity.water: 1}));
    final glut = solveLocalPrices(_mars(Biome.iceCap,
        stock: {Commodity.water: 1e5}, demand: {Commodity.water: 1},
        supply: {Commodity.water: 3}));
    expect(short.price(Commodity.water), greaterThan(neutral));
    expect(glut.price(Commodity.water), lessThan(neutral));
  });

  /// Another colony is a source too: tubes on a young lunar colony (no
  /// steel mill yet) are cheaper bought from a Martian colony that makes
  /// them than lifted out of Earth's well.
  test('another colony can undercut Earth as an import source', () {
    final mars = solveLocalPrices(_mars(Biome.iceCap, population: 500));
    final alone = solveLocalPrices(_moon(Biome.barren));
    final trading =
        solveLocalPrices(_moon(Biome.barren), otherMarkets: {'mars': mars});
    expect(trading.importCeiling[Commodity.tubes]!,
        lessThan(alone.importCeiling[Commodity.tubes]!));
  });

  /// The numbers the commit reports (printed, not asserted beyond the
  /// tests above).
  test('headline numbers', () {
    String o2(MarketFacts f) {
      final m = solveLocalMarket(f);
      return '${m.book.price(Commodity.oxygen).toStringAsFixed(2)}'
          ' (wage ${(m.book.wagePerWorkerS * kColonyDaySec).toStringAsFixed(1)}'
          '/day)';
    }

    // ignore: avoid_print
    print('O2 Earth ${o2(_earth())} | Mars iceCap ${o2(_mars(Biome.iceCap))}'
        ' | Mars desert ${o2(_mars(Biome.desert))}'
        ' | Moon barren ${o2(_moon(Biome.barren))}'
        ' | import ${solveLocalPrices(_mars(Biome.iceCap)).importCeiling[Commodity.oxygen]!.toStringAsFixed(0)}');
  });
}
