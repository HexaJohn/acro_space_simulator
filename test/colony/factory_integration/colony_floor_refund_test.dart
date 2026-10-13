// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Building and tearing down a floor plant never makes ore
/// (docs/plans/factory-floors.md §3 "Design before building": build cost
/// scales with the floor). Placement charges a designed floor's capex, so
/// the bulldozer must refund a share of what was PAID, and kit stripped off
/// a built floor is salvage, not a full refund.
library;

import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_capex.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_colony_fixture.dart';

/// Places [type] at grid [cell] as the builder does: charges
/// [CityFactories.buildCostOf], then places.
void buyUtil(CitySim sim, int cell, String type) {
  final spec = specOf(type);
  sim.stock[Commodity.ore] = sim.stockOf(Commodity.ore) - sim.buildCostOf(spec);
  sim.placeUtil(cell, spec);
}

void main() {
  // A bare hall costs a few ore; the nameplate refund was half of 40. Ten
  // place-and-bulldoze cycles printed ~100 ore.
  test('a cheap designed plant refunds a share of its capex', () {
    final sim = foundedColony();
    final template = factoryTemplateFor('steelmill')!;
    sim.factoryFloors.saveBlueprint(
        'bare',
        FloorBlueprint(
            name: 'bare', hall: template.hall, plantType: 'steelmill'));
    sim.selectFloorBlueprint('steelmill', 'bare');
    final cost = sim.buildCostOf(specOf('steelmill'));
    expect(cost, lessThan(specOf('steelmill').buildCost / 2),
        reason: 'cheaper than the nameplate refund: the exploit\'s premise');
    sim.stock[Commodity.ore] = 500;
    for (var i = 0; i < 10; i++) {
      buyUtil(sim, 5, 'steelmill');
      expect(sim.floorIsDesigned(CitySim.siteIdOfCell(5)), isTrue);
      sim.clearCell(5);
    }
    expect(sim.stockOf(Commodity.ore), lessThanOrEqualTo(500));
    expect(sim.stockOf(Commodity.ore),
        closeTo(500 - 10 * cost * (1 - CitySim.refundFraction), 1e-6));
  });

  // Strip a template's kit (salvage credited once measured), then
  // bulldoze: never more back than the 40 ore paid.
  test('place, strip and bulldoze returns less than it cost', () {
    final sim = foundedColony();
    sim.stock[Commodity.ore] = 500;
    sim.population = 300; // every handler the template hires is unlocked
    buyUtil(sim, 5, 'steelmill');
    final site = CitySim.siteIdOfCell(5);
    final floor = sim.openFloor(site)!;
    for (final p in [...floor.blueprint.placements]) {
      floor.remove(p.id);
    }
    final out = sim.closeFloor(site);
    expect(out.capexDelta, lessThan(0), reason: 'kit was freed');
    final rec = sim.factoryFloors[site]!;
    expect(sim.applyFloorMeasure(site, rec.rates, rev: rec.rev), isTrue);
    sim.clearCell(5);
    expect(sim.stockOf(Commodity.ore), lessThan(500));
  });

  // A design whose edit is still unpaid refunds only what was paid.
  test('an unpaid edit is not refunded', () {
    final sim = foundedColony();
    buyUtil(sim, 5, 'steelmill');
    final site = CitySim.siteIdOfCell(5);
    final rec = sim.factoryFloors[site]!..designed = true;
    sim.pendingFloorInvestment[site] = 10;
    expect(sim.floorBuildValueOf(site, specOf('steelmill')),
        closeTo(capexOf(rec.blueprint).total - 10, 1e-9));
  });
}
