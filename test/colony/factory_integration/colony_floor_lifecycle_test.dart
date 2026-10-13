// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A floor lives and dies with its plant, and survives a save
/// (docs/plans/factory-floors.md Â§3 "Persistence"): lot renames carry it,
/// every way a plant is lost drops it, an old save is back-filled with
/// templates, and a designed floor round-trips. Plus the stock panel's
/// COMPONENTS section for floor intermediates.
library;

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_colony_fixture.dart';

/// A bare colony with one street, as the road tests build it.
CitySim streetColony() => CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20, latitude: 0, longitude: 0),
      bodies: fixtureBodies(),
      id: 'c',
      name: 'c',
    )..funds = 1e6;

/// Lot ids holding a floor plant.
Set<String> plantLots(CitySim sim) => {
      for (final e in sim.parcelBuildings.entries)
        if (isFloorPlant(e.value)) e.key,
    };

/// The floors keyed by lots (not grid cells).
Set<String> lotFloors(CitySim sim) => {
      for (final id in sim.factoryFloors.siteIds)
        if (CitySim.cellOfSiteId(id) == null) id,
    };

CitySim reload(Map<String, dynamic> json) => CitySim.fromJson(
      (jsonDecode(jsonEncode(json)) as Map).cast<String, dynamic>(),
      bodies: fixtureBodies(),
    )
      ..hostility = 0
      ..pinPopulation = true;

void main() {
  final mill = specOf('steelmill');

  group('lot renames and drops', () {
    // A cross street re-cuts the block, renaming the lots it splits; the
    // floors go where their plants went. Without the carry they'd stay on
    // dead ids and be dropped, losing every design along the street.
    test('a road that renames lots carries their floors', () {
      final sim = streetColony();
      sim.commitRoad(const [Vec2(0, -300), Vec2(0, 300)], RoadClass.street);
      final placed = <String>{};
      for (final lot in sim.layout.autoParcels) {
        if (sim.placeOnParcel(lot.id, mill)) placed.add(lot.id);
      }
      for (final id in placed) {
        sim.factoryFloors[id]!.designed = true;
      }
      sim.commitRoad(const [Vec2(-150, 40), Vec2(150, 40)], RoadClass.street);
      expect(plantLots(sim), isNotEmpty);
      expect(plantLots(sim).difference(placed), isNotEmpty,
          reason: 'the cross street did rename lots');
      expect(lotFloors(sim), plantLots(sim));
      for (final id in lotFloors(sim)) {
        expect(sim.floorIsDesigned(id), isTrue,
            reason: '$id: the design moved with its plant');
      }
    });

    // A road cut shorter drops the lots it gave up, and their floors; a
    // grid floor is not a lot and stays (dropMissing(lots) would kill it).
    test('a road cut shorter drops the lost lots\' floors only', () {
      final sim = streetColony();
      sim.commitRoad(const [Vec2(0, 0), Vec2(0, 300)], RoadClass.street);
      final near = sim.layout.autoParcels.firstWhere((p) => p.centroid.n < 50);
      final far =
          sim.layout.autoParcels.firstWhere((p) => p.centroid.n > 200);
      expect(sim.placeOnParcel(near.id, mill), isTrue);
      expect(sim.placeOnParcel(far.id, mill), isTrue);
      sim.placeUtil(5, mill);
      final r = sim.moveRoadEnd('r0', atStart: false, to: const Vec2(0, 100));
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      expect(plantLots(sim), hasLength(1));
      expect(lotFloors(sim), plantLots(sim));
      expect(sim.factoryFloors[CitySim.siteIdOfCell(5)], isNotNull,
          reason: 'the grid floor is not a lot');
    });
  });

  group('demolition', () {
    test('clearParcel drops the floor', () {
      final sim = foundedColony();
      final lot = placeOnFreeLot(sim, mill);
      sim.pendingFloorInvestment[lot] = 3;
      sim.clearParcel(lot);
      expect(sim.factoryFloors[lot], isNull);
      expect(sim.pendingFloorInvestment.containsKey(lot), isFalse);
    });

    // placeUtil clears the cell first; clearing must only drop a floor when
    // a building stood there, and re-placing gives a fresh one.
    test('clearCell and flattenAt drop a grid floor', () {
      final sim = foundedColony();
      final site = CitySim.siteIdOfCell(5);
      sim.placeUtil(5, mill);
      expect(sim.factoryFloors[site], isNotNull);
      sim.clearCell(5);
      expect(sim.factoryFloors[site], isNull);
      sim.placeUtil(5, mill);
      sim.flattenAt(5);
      expect(sim.factoryFloors[site], isNull);
    });

    // A grid site re-built as something else loses its floor.
    test('re-placing a cell with a non-plant drops its floor', () {
      final sim = foundedColony();
      sim.placeUtil(5, mill);
      sim.placeUtil(5, specOf('solar'));
      expect(sim.factoryFloors[CitySim.siteIdOfCell(5)], isNull);
    });

    // A lot fire that burns the plant down takes its floor.
    test('a burned-out lot loses its floor', () {
      final sim = foundedColony();
      final lot = placeOnFreeLot(sim, mill);
      sim.lotFires[lot] = 0.9999;
      for (var i = 0; i < 4 && sim.parcelBuildings.containsKey(lot); i++) {
        sim.advance(0.5);
      }
      expect(sim.parcelBuildings.containsKey(lot), isFalse,
          reason: 'the fire took it');
      expect(sim.factoryFloors[lot], isNull);
    });
  });

  group('persistence', () {
    // An old save has no 'factories' key: loading back-fills template
    // floors, and the colony runs exactly as the original does.
    test('an old save loads, back-fills templates and runs the same', () {
      final sim = foundedColony();
      sim.population = 300;
      final lot = placeOnFreeLot(sim, mill);
      final json = sim.toJson();
      expect(json.containsKey('factories'), isTrue);
      final old = Map<String, dynamic>.of(json)..remove('factories');
      final fromOld = reload(old);
      final fromNew = reload(json);
      final rec = fromOld.factoryFloors[lot];
      expect(rec, isNotNull, reason: 'back-filled');
      expect(rec!.designed, isFalse);
      expect(rec.rates.outPerS, mill.outputs);
      for (final c in [fromOld, fromNew]) {
        c.population = 300;
        c.stock['steel'] = 0;
        for (var i = 0; i < 120; i++) {
          c.advance(0.5);
        }
      }
      expect(fromOld.stockOf('steel'), greaterThan(10));
      expect(fromOld.stockOf('steel'),
          closeTo(fromNew.stockOf('steel'), fromNew.stockOf('steel') * 0.02));
    });

    // A designed, measured floor, the library, the pick and the capex owed
    // all come back exactly.
    test('a designed floor round-trips', () {
      final sim = foundedColony();
      final lot = placeOnFreeLot(sim, mill);
      final bp = factoryTemplateFor('steelmill')!.copy(name: 'Mine');
      bp.roster[HandlerKind.forklift] = 4;
      sim.factoryFloors.saveBlueprint('Mine', bp);
      sim.selectFloorBlueprint('steelmill', 'Mine');
      sim.factoryFloors.assign(lot, bp,
          designed: true,
          rates: const MeasuredRates(
              inPerS: {'ore': 2.1}, outPerS: {'steel': 1.9, 'tubes': 0.5},
              powerKw: 31000, jobs: 30, seconds: 240));
      sim.pendingFloorInvestment[lot] = 1.6;
      final loaded = reload(sim.toJson());
      expect(jsonEncode(loaded.factoryFloors.toJson()),
          jsonEncode(sim.factoryFloors.toJson()));
      expect(loaded.selectedFloorBlueprint, {'steelmill': 'Mine'});
      expect(loaded.pendingFloorInvestment, {lot: 1.6});
      expect(loaded.floorIsDesigned(lot), isTrue);
      expect(loaded.factoryFloors[lot]!.rates.outPerS['steel'], 1.9);
      expect(loaded.floorsNeedingMeasure, isEmpty);
    });

    // A colony without plants saves no factory keys at all.
    test('no plants, no factory keys', () {
      final sim = streetColony();
      final json = sim.toJson();
      expect(json.containsKey('factories'), isFalse);
      expect(json.containsKey('floorPicks'), isFalse);
      expect(json.containsKey('floorCapexDue'), isFalse);
    });
  });

  // Floor intermediates shipped to stock list under COMPONENTS with their
  // own names; existing commodities keep their sections.
  test('floor intermediates are COMPONENTS with their item labels', () {
    expect(Commodity.section('pigIron'), 'COMPONENTS');
    expect(Commodity.name('pigIron'), 'Pig Iron');
    expect(Commodity.section('slag'), 'COMPONENTS');
    expect(Commodity.section(Commodity.guns), 'FINISHED GOODS');
    expect(Commodity.section(Commodity.ore), 'RAW RESOURCES');
    expect(Commodity.name(Commodity.steel), 'Steel');
    expect(Commodity.section('nothing-known'), 'FINISHED GOODS');
    expect(Commodity.name('nothing-known'), 'nothing-known');
  });
}
