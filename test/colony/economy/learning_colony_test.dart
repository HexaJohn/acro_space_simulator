// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Learning curves and invention in a live colony
/// (docs/plans/dynamic-markets.md phase 2): the colony's own production is
/// its experience and lowers its unit cost; a good not yet invented is
/// refused by the colony, its factory floors and the cost solve, and has no
/// import source; research invents it early; the state is saved; and it is
/// deterministic.
library;

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/earth_market.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/learning.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/local_prices.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/templates/rocketfactory_template.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory/factory_test_support.dart';
import '../factory_integration/economy_fixture.dart';
import '../factory_integration/factory_colony_fixture.dart';

const String kRp = Commodity.rocketParts;

/// The game's seeds, but rocket parts not invented until world day [day]:
/// a good that "doesn't exist yet", on a colony that can otherwise build
/// its plant.
TechCatalog latePartsCatalog({double day = 20}) => TechCatalog({
      ...kTechSeeds,
      kRp: TechSeed(
        learningRate: 0.20,
        firstUnitPremium: 20,
        inventionDay: day,
        firstLotUnits: 500,
        maturePrice: 20000,
      ),
    });

/// [f] with no learning multipliers: the colony's MATURE costs.
MarketFacts matureFacts(MarketFacts f) => MarketFacts(
      bodyId: f.bodyId,
      economy: f.economy,
      solarFactor: f.solarFactor,
      waterMult: f.waterMult,
      oreMult: f.oreMult,
      atmosphere: f.atmosphere,
      stock: f.stock,
      demandPerS: f.demandPerS,
      supplyPerS: f.supplyPerS,
      population: f.population,
      foodMult: f.foodMult,
      surfacePressureKPa: f.surfacePressureKPa,
      airDensity: f.airDensity,
      o2Harvestable: f.o2Harvestable,
      powerFactors: f.powerFactors,
      canExport: f.canExport,
      unavailable: f.unavailable,
      noEarthSource: f.noEarthSource,
      wageRatio: f.wageRatio,
    );

/// [runDays] at [population] people: the rocket parts recipe opens at 400,
/// above the fixture's 300.
void runDaysAt(CitySim sim, double days, double population,
    {List<CityBuildingSpec> specs = const []}) {
  final ticks = (days * 120 / kEconTickS).round();
  for (var i = 0; i < ticks; i++) {
    sim.population = population;
    for (final s in specs) {
      holdStock(sim, s, inputs: 1e5);
    }
    sim.advance(kEconTickS);
  }
}

void main() {
  setUpAll(ensureFactoryCatalog);

  // Floor and flat plants alike build the colony's experience, and its unit
  // cost is its mature cost times its learning multiplier.
  test('a colony\'s own production lowers its own unit cost', () {
    final sim = economyColony();
    placePlant(sim, 'electronics');
    final tech = sim.colonyEconomy.tech;
    const g = Commodity.electronics;
    final m0 = tech.localCostMultiplier(g);
    runDays(sim, 5.01, specs: [specOf('electronics')], inputs: 1e5);
    // The floor plant: 0.6 boards/s at its template rate for five days,
    // times the colony's bounty (what it ships is what the colony gets).
    final made = 0.6 * 5 * 120 * sim.bountyMult;
    expect(tech.localQOf(g), closeTo(made, made * 0.25));
    // The starter farm is a flat plant: its food counts too.
    expect(tech.localQOf(Commodity.food), greaterThan(0));
    final m5 = tech.localCostMultiplier(g);
    expect(m5, lessThan(m0), reason: 'experience took premium off');
    // The hook: the solve's unit cost is the mature cost × the multiplier.
    // On Earth every input sits at Earth's price, so the two solves differ
    // in that one factor only.
    final facts = sim.marketFacts();
    final learned = solveLocalMarket(facts).localCost[g]!;
    final mature = solveLocalMarket(matureFacts(facts)).localCost[g]!;
    expect(facts.learningMult[g], m5);
    expect(learned / mature, closeTo(m5, m5 * 1e-6));
    // Water and oxygen never carry a premium.
    expect(facts.learningMult.containsKey(Commodity.water), isFalse);
  });

  test('before invention: the colony, its floors and the solve refuse it', () {
    final sim = economyColony();
    sim.colonyEconomy.tech = TechState(catalog: latePartsCatalog());
    sim.population = 1000; // past every population milestone
    final parts = specOf('rocketfactory');
    expect(sim.unlocked(parts), isFalse);
    final why = sim.inventionRefusal(parts)!;
    expect(why, contains('Rocket Parts is not invented yet'));
    expect(why, contains('20 days'));
    expect(why, contains('Research can invent it early'));
    // A plant that USES it is refused too; one that doesn't is not.
    expect(sim.unlocked(specOf('missilefactory')), isFalse);
    expect(sim.inventionRefusal(specOf('missilefactory')), contains('Rocket Parts'));
    expect(sim.unlocked(specOf('steelmill')), isTrue);
    expect(sim.inventionRefusal(specOf('steelmill')), isNull);
    expect(() => placePlant(sim, 'rocketfactory'), throwsStateError,
        reason: 'no lot will take a plant for a good that does not exist');
    // The unlock cheat waives it, as it waives the milestones.
    sim.ignoreUnlocks = true;
    expect(sim.unlocked(parts), isTrue);
    sim.ignoreUnlocks = false;

    // A factory floor refuses any recipe that makes or uses it.
    final u = sim.factoryUnlocks;
    expect(u.uninvented, {kRp});
    expect(u.allowsRecipe(RocketPartsRecipes.assemble.id), isFalse);
    expect(u.recipeRefusal(RocketPartsRecipes.assemble.id),
        'Rocket Parts is not invented yet');
    expect(u.allowsRecipe(RocketPartsRecipes.weldFrame.id), isTrue);
    final l = Lay();
    l.add(EntityKind.machine, 2, 2,
        recipe: RocketPartsRecipes.weldFrame.id, mode: MachineMode.manual);
    final floor = FactoryFloor.fromBlueprint(l.blueprint(12, 10), unlocks: u);
    expect(floor.setRecipe(1, RocketPartsRecipes.assemble.id).refusal,
        EditRefusal.notAllowed);
    expect(
        floor
            .check(Placement(
                id: 0,
                kind: EntityKind.machine,
                pos: const TilePos(7, 5),
                recipe: RocketPartsRecipes.assemble.id,
                mode: MachineMode.manual))
            .refusal,
        EditRefusal.notAllowed);
    expect(floor.setRecipe(1, RocketPartsRecipes.wireAvionics.id).ok, isTrue);

    // The market has no source and no recipe: no price at all.
    runDays(sim, 1.01);
    expect(sim.colonyEconomy.earthMarket.goods.containsKey(kRp), isFalse);
    final book = sim.localPrices!;
    expect(book.price(kRp), 0);
    expect(book.importCeiling.containsKey(kRp), isFalse);
    expect(sim.colonyEconomy.colonyMarket.goods.containsKey(kRp), isFalse);
  });

  // The user's decision §7.1: colony research can invent a good early for
  // that colony. It then has the good alone, at its own first-lot premium,
  // with no import source: a real first-mover rent until Earth catches up.
  test('research invents a good early; Earth catches up on its day', () {
    final sim = economyColony();
    sim.colonyEconomy.tech = TechState(catalog: latePartsCatalog());
    final cost = sim.inventEarlyCost(kRp)!;
    expect(cost, closeTo(kDefaultInventEarlyResearch * (1 + 20 / 365.25), 1e-6));
    sim.research = cost - 1;
    expect(sim.canInventEarly(kRp), isFalse);
    expect(sim.inventEarly(kRp), isFalse);
    expect(sim.research, cost - 1, reason: 'nothing spent');
    sim.research = cost + 5;
    expect(sim.canInventEarly(kRp), isTrue);
    expect(sim.inventEarly(kRp), isTrue);
    expect(sim.research, closeTo(5, 1e-6));
    expect(sim.canInventEarly(kRp), isFalse, reason: 'once');
    expect(sim.goodInvented(kRp), isTrue);
    sim.population = 1000;
    expect(sim.unlocked(specOf('rocketfactory')), isTrue);

    final parts = specOf('rocketfactory');
    placePlant(sim, 'rocketfactory');
    expect(sim.factoryUnlocks.uninvented, isEmpty);
    runDaysAt(sim, 5.01, 1000, specs: [parts]);
    final e = sim.colonyEconomy;
    expect(e.earthMarket.goods.containsKey(kRp), isFalse,
        reason: 'Earth still has none');
    final book = sim.localPrices!;
    expect(book.importCeiling.containsKey(kRp), isFalse, reason: 'no imports');
    expect((book.exportFloor[kRp] ?? 0), 0, reason: 'nobody to sell to');
    // Dear: made at nearly the first lot's 21× premium.
    final mult = e.tech.localCostMultiplier(kRp);
    expect(mult, greaterThan(10));
    // Against the colony's own Earth market: since phase 3 Earth's prices
    // are derived (`mature_cost.dart`), and a bare solve's fallback, the
    // old seed table, would price the inputs far dearer than the colony
    // pays.
    final mature = solveLocalMarket(matureFacts(sim.marketFacts()),
            earthPrices: e.earthMarket.prices)
        .localCost[kRp]!;
    expect(book.price(kRp), greaterThan(mature * 5),
        reason: 'the first mover\'s price is far above its mature cost');
    expect(e.tech.localQOf(kRp), greaterThan(0));

    // Earth invents it on world day 20 and starts trading it, dear.
    runDaysAt(sim, 16, 1000, specs: [parts]);
    expect(e.tech.worldDay, greaterThanOrEqualTo(20));
    expect(e.earthMarket.goods.containsKey(kRp), isTrue);
    expect(e.earthMarket.priceOf(kRp)!, greaterThan(20000 * 15),
        reason: 'born near mature × 21');
    expect(sim.localPrices!.importCeiling.containsKey(kRp), isTrue);
    expect(sim.drainEconomyNotices().join(' '),
        contains("Earth's industry has begun making Rocket Parts"));
  });

  test('learning is saved; an old save is seeded with no jump', () {
    final sim = economyColony();
    final mill = specOf('steelmill');
    placePlant(sim, 'steelmill');
    runDays(sim, 3.5, specs: [mill], inputs: 1e5);
    final json = sim.toJson();
    expect(json.containsKey('tech'), isTrue);
    final tech = (json['tech'] as Map).cast<String, Object?>();
    expect(tech['day'], 3);
    expect((tech['lq'] as Map).containsKey(Commodity.steel), isTrue);
    final loaded = reload(json);
    expect(jsonEncode(loaded.colonyEconomy.tech.toJson()),
        jsonEncode(sim.colonyEconomy.tech.toJson()));
    // And they carry on together (local Q within the floor's unsaved
    // runtime state's last digits, economy_persistence_test's reason).
    runDays(sim, 3, specs: [mill], inputs: 1e5);
    runDays(loaded, 3, specs: [mill], inputs: 1e5);
    final a = sim.colonyEconomy.tech, b = loaded.colonyEconomy.tech;
    expect(b.worldDay, a.worldDay);
    for (final g in a.worldQ.keys) {
      expect(b.worldQOf(g), closeTo(a.worldQOf(g), a.worldQOf(g) * 1e-6),
          reason: g);
    }
    expect(b.localQOf(Commodity.steel),
        closeTo(a.localQOf(Commodity.steel), a.localQOf(Commodity.steel) * 0.02));

    // A save from before learning curves (phase 1: markets, no 'tech')
    // loads at world day 0 with every curve at its seed, and its first
    // close moves Earth's prices by a day's learning, not a jump.
    final old = jsonDecode(jsonEncode(sim.toJson())) as Map<String, dynamic>;
    old.remove('tech');
    final before = sim.colonyEconomy.earthMarket.priceOf(kRp)!;
    final oldLoaded = reload(old);
    expect(oldLoaded.colonyEconomy.tech.isFresh, isTrue);
    oldLoaded.closeEconomyDay();
    final after = oldLoaded.colonyEconomy.earthMarket.priceOf(kRp)!;
    expect(after / before, closeTo(1, 1e-3));
  });

  test('early inventions are saved', () {
    final sim = economyColony();
    sim.colonyEconomy.tech = TechState(catalog: latePartsCatalog());
    sim.research = 1e9;
    expect(sim.inventEarly(kRp), isTrue);
    final json = jsonDecode(jsonEncode(sim.toJson())) as Map<String, dynamic>;
    expect((json['tech'] as Map)['early'], [kRp]);
    final loaded = reload(json);
    expect(loaded.colonyEconomy.tech.early, {kRp});
  });

  // A colony with no plant saves no plant economy, but its world clock
  // must survive: otherwise Earth's prices would climb back to their seed
  // on every load.
  test('a plantless colony keeps its world clock across a load', () {
    final sim = economyColony();
    runDays(sim, 30.01);
    final json = sim.toJson();
    expect(json.containsKey('plantEconomy'), isFalse);
    expect((json['tech'] as Map)['day'], 30);
    final loaded = reload(json);
    expect(loaded.colonyEconomy.tech.worldDay, 30);
    sim.closeEconomyDay();
    loaded.closeEconomyDay();
    final a = sim.colonyEconomy.earthMarket.priceOf(kRp)!;
    final b = loaded.colonyEconomy.earthMarket.priceOf(kRp)!;
    expect(b, closeTo(a, a * 1e-9), reason: "Earth's market was saved too");
    expect(b, lessThan(earthPrice(kRp)), reason: 'not back at the seed');
    expect((json['tech'] as Map).containsKey('earthMkt'), isTrue);
    // A colony with plants saves Earth's market once, in its plant economy.
    final withPlant = economyColony();
    placePlant(withPlant, 'steelmill');
    runDays(withPlant, 1.01, specs: [specOf('steelmill')]);
    final j2 = withPlant.toJson();
    expect((j2['tech'] as Map).containsKey('earthMkt'), isFalse);
    expect((j2['plantEconomy'] as Map).containsKey('earthMkt'), isTrue);
  });

  test('two colonies stepped alike learn identically', () {
    String run() {
      final sim = economyColony(bodyId: 'mars');
      placePlant(sim, 'steelmill');
      placePlant(sim, 'electronics');
      runDays(sim, 6,
          specs: [specOf('steelmill'), specOf('electronics')], inputs: 1e5);
      return '${jsonEncode(sim.colonyEconomy.tech.toJson())}|'
          '${economyJson(sim)}';
    }

    final a = run();
    expect(a, run());
    expect(a, contains('"lq"'));
    expect(a, contains('"wq"'));
  });
}
