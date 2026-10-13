// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Which sites get a factory floor, and what a fresh one runs on
/// (docs/plans/factory-floors.md §1, §3 "Templates"; user decision
/// 2026-10-12: placed plants only, never zoned).
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_site_rules.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_capex.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_unlocks.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_colony_fixture.dart';

void main() {
  // Every plant type that ships a template gets one the moment it is placed,
  // running on the spec's own flat rate: that is what makes floors free to
  // ignore. Without the placement hook a plant would have no floor at all;
  // without seeding it would make nothing until measured.
  test('placing each floor plant on a lot gives it a seeded template', () {
    final sim = foundedColony();
    for (final type in kFactoryPlantTypes) {
      final spec = specOf(type);
      final lot = placeOnFreeLot(sim, spec);
      final rec = sim.factoryFloors[lot];
      expect(rec, isNotNull, reason: type);
      expect(rec!.designed, isFalse, reason: type);
      expect(rec.dirty, isFalse, reason: '$type: a template needs no measure');
      expect(rec.blueprint.plantType, type);
      expect(rec.rates.inPerS, spec.inputs, reason: type);
      expect(rec.rates.outPerS, spec.outputs, reason: type);
      expect(rec.rates.jobs, spec.jobs.toDouble(), reason: type);
      expect(rec.rates.powerKw, spec.powerDraw * 1000, reason: '1 unit = 1 MW');
      expect(rec.measured, isTrue, reason: 'seeded rates move goods');
      expect(sim.floorIsDesigned(lot), isFalse);
    }
    expect(sim.floorsNeedingMeasure, isEmpty);
  });

  // The grid placement path names its site `cell-<anchor>`.
  test('a grid-placed plant gets a floor at its cell site', () {
    final sim = foundedColony();
    sim.placeUtil(5, specOf('steelmill'));
    expect(sim.factoryFloors[CitySim.siteIdOfCell(5)], isNotNull);
  });

  // User decision: zoned industry levels up and is torn down without the
  // player's say, so it never carries a floor; nor does a plant type with
  // no template.
  test('zoned industry and non-factory utilities never get a floor', () {
    final sim = foundedColony();
    final works = kZoneSpecs['industrial']![Density.high]!;
    final lot = placeOnFreeLot(sim, works);
    final solar = placeOnFreeLot(sim, specOf('solar'));
    expect(sim.factoryFloors[lot], isNull);
    expect(sim.factoryFloors[solar], isNull);
    for (var i = 0; i < 20; i++) {
      sim.advance(0.5);
    }
    for (final id in sim.factoryFloors.siteIds) {
      expect(isFloorPlant(sim.siteSpec(id)!), isTrue, reason: id);
      expect(sim.grownParcels.containsKey(id), isFalse, reason: id);
    }
  });

  // Unlock tiers follow the colony's milestone tiers, and the unlock cheat
  // opens everything; an opened floor is built with them.
  test('factory unlocks follow population tiers and the cheat', () {
    final sim = foundedColony();
    sim.population = 0;
    expect(sim.factoryUnlocks.handlers, {HandlerKind.onFoot});
    expect(sim.factoryUnlocks.modes, {MachineMode.manual});
    sim.population = 120;
    expect(sim.factoryUnlocks.handlers,
        {HandlerKind.onFoot, HandlerKind.palletJack});
    expect(sim.factoryUnlocks.modes, {MachineMode.manual, MachineMode.assisted});
    sim.population = 300;
    expect(sim.factoryUnlocks.allowsHandler(HandlerKind.forklift), isTrue);
    expect(sim.factoryUnlocks.allowsHandler(HandlerKind.crane), isTrue);
    expect(sim.factoryUnlocks.allowsHandler(HandlerKind.agv), isFalse);
    expect(sim.factoryUnlocks.allowsMode(MachineMode.automated), isFalse);
    sim.population = 600;
    expect(sim.factoryUnlocks.allowsHandler(HandlerKind.agv), isTrue);
    expect(sim.factoryUnlocks.allowsMode(MachineMode.automated), isTrue);
    sim.population = 0;
    sim.ignoreUnlocks = true;
    expect(sim.factoryUnlocks.handlers, FactoryUnlocks.all.handlers);
    expect(sim.factoryUnlocks.modes, FactoryUnlocks.all.modes);

    sim.ignoreUnlocks = false;
    sim.population = 130;
    final lot = placeOnFreeLot(sim, specOf('steelmill'));
    final floor = sim.openFloor(lot);
    expect(floor, isA<FactoryFloor>());
    expect((floor! as FactoryFloor).unlocks.handlers,
        {HandlerKind.onFoot, HandlerKind.palletJack});
  });

  group('designed blueprints', () {
    /// The steel template with two more forklifts: a real design whose
    /// capex differs from the template's.
    FloorBlueprint richer() {
      final bp = factoryTemplateFor('steelmill')!.copy(name: 'Rich Mill');
      bp.roster[HandlerKind.forklift] =
          (bp.roster[HandlerKind.forklift] ?? 0) + 2;
      return bp;
    }

    // Placing with a picked design charges that design's capex, not the
    // spec's build cost; with no pick the build cost is exactly the spec's.
    test('a picked design is placed designed, dirty and costs its capex',
        () {
      final sim = foundedColony();
      final spec = specOf('steelmill');
      expect(sim.buildCostOf(spec), spec.buildCost, reason: 'template');
      final bp = richer();
      sim.factoryFloors.saveBlueprint('Rich Mill', bp);
      sim.selectFloorBlueprint('steelmill', 'Rich Mill');
      final capex = capexOf(bp).total;
      expect(capex, isNot(closeTo(spec.buildCost, 1e-6)));
      expect(sim.buildCostOf(spec), closeTo(capex, 1e-9));

      final lot = placeOnFreeLot(sim, spec);
      final rec = sim.factoryFloors[lot]!;
      expect(rec.designed, isTrue);
      expect(rec.dirty, isTrue);
      expect(rec.blueprint.roster[HandlerKind.forklift],
          bp.roster[HandlerKind.forklift]);
      expect(rec.rates.outPerS, spec.outputs,
          reason: 'runs on the spec rate until measured');
      expect(sim.floorsNeedingMeasure, [lot]);
      expect(sim.floorIsDesigned(lot), isTrue);

      // A measurement of an older layout is stale and dropped.
      const measured = MeasuredRates(
          inPerS: {'ore': 2}, outPerS: {'steel': 1.8, 'tubes': 0.4},
          powerKw: 28000, jobs: 30, seconds: 300);
      expect(sim.applyFloorMeasure(lot, measured, rev: rec.rev - 1), isFalse);
      expect(sim.applyFloorMeasure(lot, measured, rev: rec.rev), isTrue);
      expect(sim.factoryFloors[lot]!.rates.outPerS['steel'], 1.8);
      expect(sim.floorsNeedingMeasure, isEmpty);

      // Back to the template: the spec's own cost again.
      sim.selectFloorBlueprint('steelmill', null);
      expect(sim.buildCostOf(spec), spec.buildCost);
    });

    // Claiming a site charges the design's capex, and the record is designed.
    test('claiming a site charges the design capex', () {
      final sim = foundedColony();
      final spec = specOf('rationsfactory');
      final bp = factoryTemplateFor('rationsfactory')!.copy(name: 'Big Packer');
      bp.roster[HandlerKind.palletJack] =
          (bp.roster[HandlerKind.palletJack] ?? 0) + 5;
      sim.factoryFloors.saveBlueprint('Big Packer', bp);
      sim.selectFloorBlueprint('rationsfactory', 'Big Packer');
      sim.stock['ore'] = 10000;
      // claimSite: find a centre the site rules accept near the streets.
      final found = <(double, double)>[];
      for (var e = -1500.0; e <= 1500 && found.isEmpty; e += 50) {
        for (var n = -1500.0; n <= 1500 && found.isEmpty; n += 50) {
          if (sim.siteBlockedReason(spec, Vec2(e, n)) == null) {
            found.add((e, n));
          }
        }
      }
      expect(found, isNotEmpty, reason: 'a claimable centre exists');
      final before = sim.stockOf('ore');
      final parcel = sim.claimSite(spec, Vec2(found.first.$1, found.first.$2));
      expect(parcel, isNotNull, reason: sim.blocked);
      expect(sim.stockOf('ore'), closeTo(before - capexOf(bp).total, 1e-9));
      expect(sim.factoryFloors[parcel!.id]?.designed, isTrue);
    });

    // A design whose hall is bigger than the plant's site can't be placed:
    // the preview and every placement path refuse it before the click.
    test('a blueprint that does not fit the site is refused', () {
      final sim = foundedColony();
      final spec = specOf('rationsfactory');
      final huge = FloorBlueprint(
          name: 'Hangar', plantType: 'rationsfactory',
          hall: const HallSize(400, 400)); // 800 m square vs a 320 m site
      sim.factoryFloors.saveBlueprint('Hangar', huge);
      expect(sim.placementRefusal(spec), isNull);
      sim.selectFloorBlueprint('rationsfactory', 'Hangar');
      expect(sim.placementRefusal(spec), contains('does not fit'));
      expect(sim.siteBlockedReason(spec, const Vec2(0, 0)),
          contains('does not fit'));
      expect(sim.floorBlueprintRefusal(specOf('steelmill')), isNull,
          reason: 'only the picked plant type is affected');
    });

    // Closing an edited floor reports the change in build cost and books it
    // for the economy to settle.
    test('closing an edited floor books its capex delta', () {
      final sim = foundedColony();
      sim.population = 400; // forklifts unlocked
      final lot = placeOnFreeLot(sim, specOf('steelmill'));
      final floor = sim.openFloor(lot)!;
      final before = capexOf(sim.factoryFloors[lot]!.blueprint).total;
      expect(floor.hire(HandlerKind.forklift, 1).ok, isTrue);
      final out = sim.closeFloor(lot);
      expect(out.capexBefore, closeTo(before, 1e-9));
      expect(out.capexDelta, closeTo(kCapexHandlerOre[HandlerKind.forklift]!,
          1e-9));
      expect(sim.pendingFloorInvestment[lot], closeTo(out.capexDelta, 1e-9));
      expect(out.record!.designed, isTrue);
      expect(sim.floorsNeedingMeasure, [lot]);
      // Looking without editing books nothing more.
      sim.openFloor(lot);
      expect(sim.closeFloor(lot).capexDelta, 0);
      expect(sim.pendingFloorInvestment[lot], closeTo(out.capexDelta, 1e-9));
    });
  });
}
