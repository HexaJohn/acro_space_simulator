// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The road tool's price and its refusals: what a player is quoted for a
/// road, what building it charges, and why a road cannot be built.
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_build.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bodies = RealSolarSystem.build().all.where((b) => !b.isStar).toList();
  CitySim colony({double funds = 1e6}) => CitySim.found(
        const CityConfig(
            bodyId: 'earth', gridSize: 20, latitude: 0, longitude: 0),
        bodies: bodies,
        id: 'c',
        name: 'c',
      )..funds = funds;
  RoadType type(String id) => RoadType.byId(id)!;
  const straight = [Vec2(0, 0), Vec2(400, 0)];

  RoadQuote quote(
    String id, {
    List<Vec2> controls = straight,
    double start = 0,
    double end = 0,
    double? startH,
    double? endH,
    double Function(Vec2)? groundAt,
    bool gradeGate = false,
    double funds = double.infinity,
    bool unlocked = true,
  }) =>
      quoteRoadBuild(
        RoadBuildRequest(
          controls: controls,
          type: type(id),
          startElevationM: start,
          endElevationM: end,
          startHeightM: startH,
          endHeightM: endH,
        ),
        groundAt: groundAt,
        gradeGate: gradeGate,
        funds: funds,
        unlocked: unlocked,
      );

  group('the quote', () {
    test('a straight road on the ground is priced per cell', () {
      final q = quote('two-lane');
      expect(q.ok, isTrue);
      expect(q.lengthM, closeTo(400, 1e-6));
      expect(q.cost, closeTo(50 * 40, 1e-6));
      expect(q.upkeepPerWeek, closeTo(50 * 0.32, 1e-9));
      expect(q.deck, isNull, reason: 'both ends at grade: draped');
      expect(q.structureM, 0);
      expect(q.tunnelM, 0);
      expect(q.reason, isEmpty);
    });

    test('a dense polyline prices the curve it describes', () {
      // A quarter circle of 100 m radius, evaluated by the tool at 1 degree.
      final arc = [
        for (var d = 0; d <= 90; d++)
          Vec2(100 * math.cos(d * math.pi / 180),
              100 * math.sin(d * math.pi / 180)),
      ];
      final q = quote('two-lane', controls: arc);
      expect(q.ok, isTrue);
      expect(q.lengthM, closeTo(math.pi * 50, 0.1));
      expect(q.cost, closeTo(q.lengthM / 8 * 40, 1e-6));
      // Its two ends alone are the chord.
      expect(quote('two-lane', controls: [arc.first, arc.last]).lengthM,
          closeTo(100 * math.sqrt2, 1e-6));
    });

    test('shorter than a cell is not a road', () {
      final q = quote('two-lane', controls: const [Vec2(0, 0), Vec2(5, 0)]);
      expect(q.refusal, RoadRefusal.tooShort);
      expect(q.reason, contains('8 m'));
      expect(quote('two-lane', controls: const [Vec2(0, 0)]).refusal,
          RoadRefusal.tooShort);
    });

    test('the grade gate reads the ground under a road laid on it', () {
      double hillside(Vec2 p) => p.e * 0.10; // a 10% slope
      expect(quote('highway', groundAt: hillside).ok, isTrue,
          reason: 'free build ignores the slope under a draped road');
      final steep = quote('highway', groundAt: hillside, gradeGate: true);
      expect(steep.refusal, RoadRefusal.tooSteep);
      expect(steep.gradePct, closeTo(10, 1e-6));
      expect(steep.reason, 'Slope too steep for a Highway (10.0% of 5%)');
      expect(quote('two-lane', groundAt: hillside, gradeGate: true).ok, isTrue,
          reason: 'a street takes 12%');
    });

    test('a raised road is priced on its piers', () {
      final q = quote('two-lane', start: 12, end: 12);
      expect(q.ok, isTrue, reason: q.reason);
      final deck = q.deck!;
      expect(deck.startM, 12);
      expect(deck.endM, 12);
      expect(deck.startOffsetM, 12);
      expect(deck.endOffsetM, 12);
      expect(deck.structures.single.$1, closeTo(0, 1e-9));
      expect(deck.structures.single.$2, closeTo(400, 1e-6));
      expect(q.structureM, closeTo(400, 1e-6));
      expect(q.bridgeM, 0, reason: "12 m is short of a bridge's 15");
      expect(q.cost, closeTo(2000 * RoadCosts.structureBuildMult, 1e-6));
      expect(q.upkeepPerWeek,
          closeTo(16 * RoadCosts.structureUpkeepMult, 1e-9));
    });

    test('above fifteen metres the structure is a bridge', () {
      final q = quote('two-lane', start: 24, end: 24);
      expect(q.bridgeM, closeTo(400, 1e-6));
      expect(q.cost, closeTo(2000 * RoadCosts.bridgeBuildMult, 1e-6));
    });

    test('a sunk road runs in a tunnel', () {
      final q = quote('two-lane', start: -12, end: -12);
      expect(q.ok, isTrue, reason: q.reason);
      expect(q.tunnelM, closeTo(400, 1e-6));
      expect(q.cost, closeTo(2000 * RoadCosts.tunnelBuildMult, 1e-6));
      expect(q.upkeepPerWeek, closeTo(16 * RoadCosts.tunnelUpkeepMult, 1e-9));
    });

    test('what cannot stand is refused, and says why', () {
      final gravel = quote('gravel', start: -12, end: -12);
      expect(gravel.refusal, RoadRefusal.noTunnel);
      expect(gravel.reason, 'Gravel roads cannot go underground');
      expect(quote('two-lane', start: 72, end: 60).refusal,
          RoadRefusal.tooHigh);
      expect(quote('two-lane', start: -48, end: -36).refusal,
          RoadRefusal.tooDeep);
      final viaduct = quote('elevated-highway', start: 12, end: 12);
      expect(viaduct.refusal, RoadRefusal.noElevation);
      expect(viaduct.reason, startsWith('An Elevated Highway'));
      // 36 m in 400 m is 9%: over a four-lane road's 8.
      final steep = quote('four-lane', end: 36);
      expect(steep.refusal, RoadRefusal.tooSteep);
      expect(steep.gradePct, closeTo(9, 1e-6));
    });

    test("an end joining a raised road takes that road's height", () {
      final q = quote('two-lane', startH: 30, groundAt: (_) => 20);
      final deck = q.deck!;
      expect(deck.startM, 30);
      expect(deck.startOffsetM, closeTo(10, 1e-9));
      expect(deck.endM, 20, reason: 'the other end on the ground');
      expect(deck.endOffsetM, closeTo(0, 1e-9));
    });

    test('what the road is comes before whether it is open or affordable',
        () {
      expect(quote('highway', end: 36, unlocked: false, funds: 0).refusal,
          RoadRefusal.tooSteep);
      final locked = quote('highway', unlocked: false, funds: 0);
      expect(locked.refusal, RoadRefusal.locked);
      expect(locked.reason, 'Opens at 200 population');
      final poor = quote('two-lane', funds: 100);
      expect(poor.refusal, RoadRefusal.funds);
      expect(poor.reason, 'Not enough money: §2,000 needed');
    });

    test('money is printed as the HUD prints it', () {
      expect(formatMoney(1239.2), '§1,240');
      expect(formatMoney(999), '§999');
      expect(formatMoney(1234567), '§1,234,567');
      expect(formatMoney(0), '§0');
    });
  });

  group('building', () {
    test('quoting is pure', () {
      final sim = colony(funds: 5000);
      final before = sim.roadsRevision;
      final q = sim.quoteRoad(
          RoadBuildRequest(controls: straight, type: type('two-lane')));
      expect(q.ok, isTrue);
      expect(sim.funds, 5000);
      expect(sim.layout.roads, isEmpty);
      expect(sim.roadsRevision, before);
    });

    test('a road built is laid, dressed and paid for', () {
      final sim = colony(funds: 10000)..population = 300;
      final before = sim.roadsRevision;
      final r = sim.buildRoad(
          RoadBuildRequest(controls: straight, type: type('two-lane-trees')));
      expect(r.roadId, 'r0');
      expect(r.quote.cost, closeTo(50 * 60, 1e-6));
      expect(sim.funds, closeTo(10000 - 3000, 1e-6));
      final road = sim.layout.roadById('r0')!;
      expect(road.decoration, RoadDecoration.trees);
      expect(road.deck, isNull);
      expect(road.sealed, isFalse, reason: "Earth's air is breathable");
      expect(sim.layout.autoParcels.where((p) => p.roadId == 'r0'),
          isNotEmpty);
      expect(sim.roadsRevision, greaterThan(before));
    });

    test('a refused road lays nothing and costs nothing', () {
      final sim = colony(funds: 100);
      final r = sim.buildRoad(
          RoadBuildRequest(controls: straight, type: type('two-lane')));
      expect(r.roadId, isNull);
      expect(r.quote.refusal, RoadRefusal.funds);
      expect(sim.layout.roads, isEmpty);
      expect(sim.funds, 100);
      expect(sim.blocked, r.quote.reason);
    });

    test('a Highway waits for its milestone — or the cheat', () {
      final sim = colony();
      final hwy = type('highway');
      expect(sim.roadTypeUnlocked(hwy), isFalse);
      expect(
          sim.quoteRoad(RoadBuildRequest(controls: straight, type: hwy))
              .refusal,
          RoadRefusal.locked);
      sim.ignoreUnlocks = true;
      expect(sim.roadTypeUnlocked(hwy), isTrue);
      sim.ignoreUnlocks = false;
      sim.population = 200;
      expect(sim.roadTypeUnlocked(hwy), isTrue);
    });

    test('a raised road is laid on its deck, and fronts nothing there', () {
      final sim = colony();
      final r = sim.buildRoad(RoadBuildRequest(
          controls: straight,
          type: type('two-lane'),
          startElevationM: 12,
          endElevationM: 12));
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      final deck = sim.layout.roadById(r.roadId!)!.deck!;
      expect(deck.startM, closeTo(12, 1e-9));
      expect(deck.endM, closeTo(12, 1e-9));
      expect(deck.structureM, closeTo(400, 1e-6));
      expect(sim.layout.autoParcels.where((p) => p.roadId == r.roadId),
          isEmpty,
          reason: 'there is no kerb on a bridge to build along');
    });

    test('a road built across a district carries its buildings', () {
      final sim = colony();
      sim.commitRoad(const [Vec2(-300, 0), Vec2(300, 0)], RoadClass.street);
      final clinic = kUtilCatalog.firstWhere((s) => s.label == 'Clinic');
      for (final lot in sim.layout.autoParcels.take(6)) {
        sim.parcelBuildings[lot.id] = clinic;
      }
      sim.buildRoad(RoadBuildRequest(
          controls: const [Vec2(0, -300), Vec2(0, 300)],
          type: type('two-lane')));
      expect(sim.layout.roads.length, 4, reason: 'both cut at the crossing');
      expect(sim.parcelBuildings, hasLength(6));
      final ids = {for (final p in sim.layout.parcels) p.id};
      for (final id in sim.parcelBuildings.keys) {
        expect(ids, contains(id), reason: '$id was orphaned by the rename');
      }
    });
  });
}
