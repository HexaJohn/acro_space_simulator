// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_progression.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

/// The road menu: every entry buildable, priced, and opened on a rung of
/// the milestone ladder.
void main() {
  test('ids are unique and every entry resolves back to itself', () {
    final ids = kRoadCatalog.map((t) => t.id).toSet();
    expect(ids.length, kRoadCatalog.length);
    for (final t in kRoadCatalog) {
      expect(RoadType.byId(t.id), same(t));
      final road = RoadSpline(
        id: 'r0',
        controls: const [Vec2(0, 0), Vec2(0, 100)],
        roadClass: t.roadClass,
        decoration: t.decoration,
        soundWalls: t.soundWalls,
      );
      expect(RoadType.of(road), same(t), reason: t.id);
    }
  });

  test('every class — generated or loaded — has a price', () {
    for (final cls in RoadClass.values) {
      final t = RoadType.forClass(cls);
      expect(t.roadClass, cls);
      expect(t.costPerCell, greaterThan(0));
      expect(t.upkeepPerCellWeek, greaterThan(0));
    }
  });

  test('decoration and walls are only offered where the class allows them',
      () {
    for (final t in kRoadCatalog) {
      if (t.decoration != RoadDecoration.none) {
        expect(t.roadClass.supportsDecoration, isTrue, reason: t.id);
      }
      if (t.soundWalls) {
        expect(t.roadClass.canHaveSoundWalls, isTrue, reason: t.id);
      }
    }
  });

  test('every road opens ON a milestone, never between two', () {
    final rungs = CityProgression.all.map((m) => m.population).toSet();
    for (final t in kRoadCatalog) {
      expect(rungs, contains(t.unlockPop), reason: t.id);
    }
    // The opening position can build a street, a one-way and the big roads.
    for (final id in ['gravel', 'two-lane', 'one-way', 'four-lane', 'six-lane']) {
      expect(RoadType.byId(id)!.unlockPop, 0, reason: id);
    }
  });

  test('the Cities: Skylines table, per cell', () {
    expect(RoadType.byId('two-lane')!.costPerCell, 40);
    expect(RoadType.byId('two-lane')!.upkeepPerCellWeek, 0.32);
    expect(RoadType.byId('highway')!.upkeepPerCellWeek, 0.96);
    expect(RoadType.byId('highway')!.oneWay, isTrue);
    expect(RoadType.byId('ramp')!.oneWay, isTrue);
    expect(RoadType.byId('highway')!.zonable, isFalse);
    expect(RoadType.byId('ramp')!.zonable, isFalse);
    expect(RoadType.byId('six-lane')!.zonable, isTrue);
  });

  group('costs', () {
    final hwy = RoadType.byId('highway')!;

    test('at grade: cells times the price', () {
      expect(RoadCosts.construction(hwy, lengthM: 800), closeTo(100 * 70, 1e-9));
      expect(RoadCosts.upkeepPerWeek(hwy, lengthM: 800),
          closeTo(100 * 0.96, 1e-9));
    });

    test('elevated and tunnel upkeep follow the highway\'s own rows', () {
      expect(RoadCosts.upkeepPerWeek(hwy, lengthM: 8, structureM: 8),
          closeTo(2.08, 1e-9));
      expect(RoadCosts.upkeepPerWeek(hwy, lengthM: 8, tunnelM: 8),
          closeTo(5.12, 1e-9));
    });

    test('a structure and a tunnel cost multiples to build', () {
      final ground = RoadCosts.construction(hwy, lengthM: 400);
      expect(RoadCosts.construction(hwy, lengthM: 400, structureM: 400),
          closeTo(ground * RoadCosts.structureBuildMult, 1e-6));
      expect(
          RoadCosts.construction(hwy,
              lengthM: 400, structureM: 400, bridgeM: 400),
          closeTo(ground * RoadCosts.bridgeBuildMult, 1e-6));
      expect(RoadCosts.construction(hwy, lengthM: 400, tunnelM: 400),
          closeTo(ground * RoadCosts.tunnelBuildMult, 1e-6));
    });

    test('an upgrade costs the difference; a downgrade is free', () {
      final two = RoadType.byId('two-lane')!;
      final trees = RoadType.byId('two-lane-trees')!;
      expect(RoadCosts.upgrade(two, trees, lengthM: 80), closeTo(10 * 20, 1e-9));
      expect(RoadCosts.upgrade(trees, two, lengthM: 80), 0);
    });
  });

  group('parking', () {
    test('undecorated roads with a pavement park cars; decorated do not', () {
      expect(RoadType.byId('two-lane')!.hasParking, isTrue);
      expect(RoadType.byId('two-lane-trees')!.hasParking, isFalse);
      expect(RoadType.byId('six-lane-grass')!.hasParking, isFalse);
      expect(RoadType.byId('highway')!.hasParking, isFalse);
    });

    test('a four-lane road keeps its parking whatever it is dressed in', () {
      expect(RoadType.byId('four-lane')!.hasParking, isTrue);
      expect(RoadType.byId('four-lane-trees')!.hasParking, isTrue);
    });
  });

  test('trees quiet a road more than grass; sound barriers most of all', () {
    final plain = RoadType.byId('two-lane')!.noiseEmission;
    final grass = RoadType.byId('two-lane-grass')!.noiseEmission;
    final trees = RoadType.byId('two-lane-trees')!.noiseEmission;
    expect(grass, lessThan(plain));
    expect(trees, lessThan(grass));
    expect(RoadType.byId('highway-walls')!.noiseEmission,
        lessThan(RoadType.byId('highway')!.noiseEmission * 0.5));
  });

  group('the new classes', () {
    test('keep their lanes inside their width, decorated or not', () {
      for (final cls in RoadClass.values) {
        for (final d in RoadDecoration.values) {
          final lanes = cls.lanesFor(d);
          if (lanes == null) continue;
          expect(lanes.widthM, closeTo(cls.width, 1e-9),
              reason: '${cls.name}/${d.name}');
        }
      }
    });

    test('are appended after every saved index', () {
      expect(RoadClass.ramp.index, 12);
      expect(RoadClass.streetOneWay.index, 13);
      expect(RoadClass.boulevard.index, 14);
      expect(RoadClass.motorway.index, 15);
    });

    test('a one-way street is a street\'s width, both lanes one way', () {
      final l = RoadClass.streetOneWay.lanes!;
      expect(l.oneWay, isTrue);
      expect(l.laneCount, 2);
      expect(RoadClass.streetOneWay.width, RoadClass.street.width);
      expect(RoadClass.streetOneWay.platsLots, isTrue);
      expect(RoadClass.streetOneWay.hasPavement, isTrue);
    });

    test('the highway is one way, fronts nothing and meets roads at grade',
        () {
      final m = RoadClass.motorway;
      expect(m.oneWay, isTrue);
      expect(m.lanes!.laneCount, 3);
      expect(m.platsLots, isFalse);
      expect(m.hasPavement, isFalse);
      expect(m.limitedAccess, isFalse);
      expect(m.isExpressway, isFalse,
          reason: 'the auto-bridge rule is the generator\'s, not the tool\'s');
      expect(m.joinsJunctions, isTrue);
      expect(m.canHaveSoundWalls, isTrue);
    });

    test('decorated four- and six-lane roads are planted down the middle', () {
      expect(RoadClass.avenue.lanesFor(RoadDecoration.trees)!.median,
          MedianStyle.planted);
      expect(RoadClass.boulevard.lanesFor(RoadDecoration.grass)!.median,
          MedianStyle.planted);
      expect(RoadClass.boulevard.lanesFor(RoadDecoration.none)!.median,
          MedianStyle.barrier);
      expect(RoadClass.street.lanesFor(RoadDecoration.trees),
          same(RoadClass.street.lanes),
          reason: 'a two-lane road\'s trees are on the verges');
    });

    test('gravel cannot tunnel; nothing held in the air by class moves', () {
      expect(RoadClass.path.canTunnel, isFalse);
      expect(RoadClass.street.canTunnel, isTrue);
      expect(RoadClass.elevated.canElevate, isFalse);
      expect(RoadClass.transit.canTunnel, isFalse);
    });
  });
}
