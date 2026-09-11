// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The road tool's edits on a built colony: Upgrade (and downgrade),
/// reversing a one-way road, naming a road, Adjust Roads' dragged ends,
/// junction overrides — and the save that has to remember all of it.
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_build.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/road_names.dart';
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
  final clinic = kUtilCatalog.firstWhere((s) => s.label == 'Clinic');
  const vertical = [Vec2(0, -300), Vec2(0, 300)];
  const horizontal = [Vec2(-300, 0), Vec2(300, 0)];
  // Level ground at the datum, with a valley 20 m deep from 100 m to 300 m
  // east: a road across it with both ends at grade is a bridge between.
  double valley(Vec2 p) => p.e > 100 && p.e < 300 ? -20.0 : 0.0;
  RoadBuildRequest acrossTheValley({double toE = 400}) => RoadBuildRequest(
      controls: [const Vec2(0, 0), Vec2(toE, 0)],
      type: type('two-lane'),
      startHeightM: 0,
      endHeightM: 0);

  group('upgrade', () {
    test('re-cuts the lots, carries the buildings, charges the difference',
        () {
      final sim = colony(funds: 10000);
      sim.commitRoad(vertical, RoadClass.street);
      for (final lot in sim.layout.autoParcels.take(4)) {
        sim.parcelBuildings[lot.id] = clinic;
      }
      final rev = sim.roadsRevision;
      final q = sim.upgradeRoad('r0', type('four-lane'));
      expect(q.ok, isTrue, reason: q.reason);
      expect(q.cost, closeTo(600 / 8 * (60 - 40), 1e-6));
      expect(sim.funds, closeTo(10000 - 1500, 1e-6));
      expect(sim.layout.roadById('r0')!.roadClass, RoadClass.avenue);
      expect(sim.roadsRevision, greaterThan(rev));
      expect(sim.parcelBuildings, hasLength(4));
      final ids = {for (final p in sim.layout.parcels) p.id};
      for (final id in sim.parcelBuildings.keys) {
        expect(ids, contains(id));
      }
      // Wider: the lots stand further back from the centreline.
      final lot = sim.layout.parcelById(sim.parcelBuildings.keys.first)!;
      expect(lot.frontageMidpoint!.e.abs(), closeTo(8 + 3, 1e-6));
    });

    test('a downgrade is free; the same type changes nothing', () {
      final sim = colony(funds: 10000);
      sim.commitRoad(vertical, RoadClass.avenue);
      final q = sim.upgradeRoad('r0', type('two-lane'));
      expect(q.ok, isTrue);
      expect(q.cost, 0);
      expect(sim.funds, 10000);
      expect(sim.layout.roadById('r0')!.roadClass, RoadClass.street);
      final rev = sim.roadsRevision;
      final version = sim.layout.version;
      expect(sim.upgradeRoad('r0', type('two-lane')).ok, isTrue);
      expect(sim.roadsRevision, rev, reason: 'nothing to do');
      expect(sim.layout.version, version);
    });

    test('is refused where the new type cannot be what the road is', () {
      final sim = colony(funds: 0);
      sim.commitRoad(vertical, RoadClass.street);
      expect(sim.quoteUpgrade('ghost', type('four-lane')).refusal,
          RoadRefusal.notFound);
      expect(sim.quoteUpgrade('r0', type('four-lane')).refusal,
          RoadRefusal.funds);
      expect(
          sim.quoteUpgrade('r0', type('highway')).refusal, RoadRefusal.locked);
      sim.commitRoad(const [Vec2(500, -300), Vec2(500, 300)], RoadClass.street,
          deck: const RoadDeck(
              startM: -12,
              endM: -12,
              startOffsetM: -12,
              endOffsetM: -12,
              tunnels: [(0, 600)]));
      expect(sim.quoteUpgrade('r1', type('gravel')).refusal,
          RoadRefusal.noTunnel);
      expect(sim.upgradeRoad('r1', type('gravel')).ok, isFalse);
      expect(sim.layout.roadById('r1')!.roadClass, RoadClass.street);
    });

    test('a county highway upgraded to six lanes is zoned at last', () {
      final sim = colony()..ignoreUnlocks = true;
      // What the generator lays: an avenue told to front nothing.
      sim.commitRoad(vertical, RoadClass.avenue, frontsLots: false);
      expect(sim.layout.autoParcels.where((p) => p.roadId == 'r0'), isEmpty);
      final q = sim.upgradeRoad('r0', type('six-lane'));
      expect(q.ok, isTrue, reason: q.reason);
      expect(sim.layout.roadById('r0')!.roadClass, RoadClass.boulevard);
      expect(sim.layout.autoParcels.where((p) => p.roadId == 'r0'),
          isNotEmpty);
    });

    test('with the ground to see, a bridge upgrades at the bridge price', () {
      final sim = colony();
      final b = sim.buildRoad(acrossTheValley(), groundAt: valley);
      expect(b.quote.bridgeM, closeTo(200, 1e-6));
      final seen = sim.quoteUpgrade('r0', type('four-lane'), groundAt: valley);
      expect(seen.bridgeM, closeTo(200, 1e-6));
      expect(seen.cost,
          closeTo((25 + 25 * RoadCosts.bridgeBuildMult) * (60 - 40), 1e-6));
      // Blind, the ends at grade say nothing of the valley between them:
      // the span prices as mere piers.
      final blind = sim.quoteUpgrade('r0', type('four-lane'));
      expect(blind.bridgeM, 0);
      expect(blind.cost,
          closeTo((25 + 25 * RoadCosts.structureBuildMult) * (60 - 40), 1e-6));
      final funds = sim.funds;
      expect(sim.upgradeRoad('r0', type('four-lane'), groundAt: valley).ok,
          isTrue);
      expect(sim.funds, closeTo(funds - seen.cost, 1e-6));
    });
  });

  group('reverse', () {
    test('turns a one-way road round and keeps every lot', () {
      final sim = colony();
      sim.commitRoad(vertical, RoadClass.streetOneWay);
      final lot = sim.layout.autoParcels.first;
      sim.parcelBuildings[lot.id] = clinic;
      final lots = [for (final p in sim.layout.autoParcels) p.id];
      final rev = sim.roadsRevision;
      expect(sim.reverseRoad('r0'), isTrue);
      final road = sim.layout.roadById('r0')!;
      expect(road.reversed, isTrue);
      expect(road.travelStart.n, closeTo(300, 1e-6));
      expect([for (final p in sim.layout.autoParcels) p.id], lots);
      expect(sim.parcelBuildings.keys, [lot.id]);
      expect(sim.roadsRevision, greaterThan(rev));
    });

    test('a two-way road has no direction to reverse', () {
      final sim = colony();
      sim.commitRoad(vertical, RoadClass.street);
      expect(sim.reverseRoad('r0'), isFalse);
      expect(sim.blocked, 'Only a one-way road has a direction to reverse');
      expect(sim.reverseRoad('ghost'), isFalse);
    });
  });

  group('names', () {
    test('a name is given to every piece of the road', () {
      final sim = colony();
      sim.commitRoad(horizontal, RoadClass.street);
      sim.commitRoad(vertical, RoadClass.street);
      expect(sim.layout.roadById('r0x0'), isNotNull);
      final rev = sim.roadsRevision;
      expect(sim.renameRoad('r0x1', '  High Street '), isTrue);
      expect(sim.layout.roadById('r0x0')!.name, 'High Street');
      expect(sim.layout.roadById('r0x1')!.name, 'High Street');
      expect(sim.layout.roadById('r1x0')!.name, isNull, reason: 'another road');
      expect(sim.roadNameOf('r0x0'), 'High Street');
      expect(sim.roadsRevision, greaterThan(rev));
      sim.renameRoad('r0x0', null);
      expect(sim.roadNameOf('r0x1'), RoadNames.generated('r0', RoadClass.street));
      expect(sim.renameRoad('ghost', 'x'), isFalse);
    });

    test('a generated name is the same for every piece, on every load', () {
      final sim = colony();
      sim.commitRoad(horizontal, RoadClass.street);
      sim.commitRoad(vertical, RoadClass.street);
      final name = sim.roadNameOf('r0x0');
      expect(name, endsWith(' Street'));
      expect(sim.roadNameOf('r0x1'), name);
      final back = CitySim.fromJson(sim.toJson(), bodies: bodies);
      expect(back.roadNameOf('r0x0'), name);
      expect(RoadNames.suffixFor(RoadClass.ramp), 'Ramp');
      expect(RoadNames.suffixFor(RoadClass.motorway), 'Highway');
      expect(RoadNames.suffixFor(RoadClass.boulevard), 'Boulevard');
      // Roads laid one after another are not all one street.
      final names = {
        for (var i = 0; i < 20; i++) RoadNames.generated('r$i', RoadClass.street)
      };
      expect(names.length, greaterThan(10));
    });

    test("a player's name on any piece of the road wins", () {
      final sim = colony();
      sim.commitRoad(horizontal, RoadClass.street);
      sim.commitRoad(vertical, RoadClass.street);
      sim.layout.renameRoad('r0x1', 'Quay'); // one piece only
      expect(sim.roadNameOf('r0x0'), 'Quay');
      expect(sim.roadNameOf('r1x0'), isNot('Quay'));
    });
  });

  group('adjust roads', () {
    test('dragging an end re-lays the piece and charges what it adds', () {
      final sim = colony(funds: 10000);
      sim.commitRoad(const [Vec2(0, 0), Vec2(0, 300)], RoadClass.street);
      final lot = sim.layout.autoParcels.firstWhere((p) => p.centroid.n < 100);
      sim.parcelBuildings[lot.id] = clinic;
      final before = sim.roadNameOf('r0');
      final rev = sim.roadsRevision;
      final r = sim.moveRoadEnd('r0', atStart: false, to: const Vec2(0, 400));
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      expect(r.roadId, 'r0x0');
      expect(sim.layout.roadById('r0'), isNull);
      final road = sim.layout.roadById('r0x0')!;
      expect(road.controls.first.n, closeTo(0, 1e-6));
      expect(road.controls.last.n, closeTo(400, 1e-6));
      expect(r.quote.cost, closeTo(100 / 8 * 40, 1e-6));
      expect(sim.funds, closeTo(10000 - 500, 1e-6));
      expect(sim.roadNameOf('r0x0'), before, reason: 'the same street');
      expect(sim.roadsRevision, greaterThan(rev));
      // The building stands on the lot now where its lot stood.
      final ids = {for (final p in sim.layout.parcels) p.id};
      expect(sim.parcelBuildings.keys.single, isIn(ids));
      expect(sim.parcelBuildings.keys.single, isNot(lot.id));
    });

    test('shortening a road is free', () {
      final sim = colony(funds: 10000);
      sim.commitRoad(const [Vec2(0, 0), Vec2(0, 300)], RoadClass.street);
      final r = sim.moveRoadEnd('r0', atStart: true, to: const Vec2(0, 50));
      expect(r.quote.ok, isTrue);
      expect(r.quote.cost, 0);
      expect(sim.funds, 10000);
      expect(sim.layout.roadById(r.roadId!)!.controls.first.n,
          closeTo(50, 1e-6));
    });

    test('every attribute rides the re-lay', () {
      final sim = colony();
      sim.commitRoad(const [Vec2(0, 0), Vec2(0, 300)], RoadClass.streetOneWay,
          decoration: RoadDecoration.grass,
          reversed: true,
          name: 'Mews',
          collector: true,
          graded: false,
          lotFrontageM: 18);
      final r = sim.moveRoadEnd('r0', atStart: false, to: const Vec2(40, 350));
      final road = sim.layout.roadById(r.roadId!)!;
      expect(road.roadClass, RoadClass.streetOneWay);
      expect(road.decoration, RoadDecoration.grass);
      expect(road.reversed, isTrue);
      expect(road.name, 'Mews');
      expect(road.collector, isTrue);
      expect(road.graded, isFalse);
      expect(road.lotFrontageM, 18);
    });

    test('a raised road keeps the height of the end left alone', () {
      final sim = colony();
      sim.commitRoad(const [Vec2(0, 0), Vec2(0, 400)], RoadClass.street,
          deck: const RoadDeck(
              startM: 0, endM: 12, endOffsetM: 12, structures: [(100, 400)]));
      final r = sim.moveRoadEnd('r0',
          atStart: false, to: const Vec2(0, 480), groundAt: (_) => 2);
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      final deck = sim.layout.roadById(r.roadId!)!.deck!;
      expect(deck.startM, closeTo(0, 1e-9), reason: 'the end left alone');
      expect(deck.endM, closeTo(2 + 12, 1e-9),
          reason: 'as high above its new ground as it stood above the old');
    });

    test('a moved end joins the road it is dropped on', () {
      final sim = colony();
      sim.commitRoad(const [Vec2(-300, 500), Vec2(300, 500)], RoadClass.street);
      sim.commitRoad(const [Vec2(0, 0), Vec2(0, 300)], RoadClass.street);
      final r = sim.moveRoadEnd('r1', atStart: false, to: const Vec2(0, 505));
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      expect(sim.layout.roadById(r.roadId!)!.controls.last.n,
          closeTo(500, 1e-6),
          reason: 'snapped onto it');
      expect(sim.layout.roadById('r0'), isNull,
          reason: 'the road it lands on is cut for the T');
      expect(sim.layout.roads.length, 3);
    });

    // Rolling ground, which a street laid on it follows: laid as a deck, a
    // straight grade line between its ends, it would be cut, piered and
    // tunnelled through every rise and dip.
    double rolling(Vec2 p) =>
        8 * math.sin(p.n / 30) + 4 * math.sin(p.e / 25);

    test('a road on the ground is re-laid on the ground — draped, no deck, '
        'its direction and its lots kept', () {
      final sim = colony(funds: 10000);
      final b = sim.buildRoad(
          RoadBuildRequest(
              controls: const [Vec2(0, 0), Vec2(0, 200)],
              type: type('one-way')),
          groundAt: rolling);
      expect(b.quote.ok, isTrue, reason: b.quote.reason);
      final id = b.roadId!;
      expect(sim.layout.roadById(id)!.deck, isNull);
      expect(sim.reverseRoad(id), isTrue);
      final lot = sim.layout.autoParcels.firstWhere((p) => p.centroid.n < 50);
      sim.parcelBuildings[lot.id] = clinic;

      final r = sim.moveRoadEnd(id,
          atStart: false, to: const Vec2(20, 260), groundAt: rolling);
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      expect(r.quote.deck, isNull);
      expect(r.quote.structureM + r.quote.tunnelM, 0);
      final road = sim.layout.roadById(r.roadId!)!;
      expect(road.deck, isNull, reason: 'draped on the ground, as it was');
      expect(road.graded, isTrue, reason: 'its corridor graded, not a deck');
      expect(road.reversed, isTrue, reason: 'still one way, the same way');
      expect(road.travelStart.distanceTo(const Vec2(20, 260)), lessThan(1e-6));
      final ids = {for (final p in sim.layout.parcels) p.id};
      expect(sim.parcelBuildings.keys.single, isIn(ids),
          reason: 'the building stands on the lot now where its lot stood');
    });

    test('a height that is the ground asks for no deck: a street brought to '
        'the foot of a ramp stays on the ground', () {
      final sim = colony();
      // Down from 12 m to the ground at (0, 200).
      final ramp = sim
          .buildRoad(
              RoadBuildRequest(
                  controls: const [Vec2(0, 0), Vec2(0, 200)],
                  type: type('two-lane'),
                  startElevationM: 12),
              groundAt: rolling)
          .roadId!;
      final foot = sim.layout.roadById(ramp)!.deck!;
      expect(foot.endAtGrade, isTrue);
      final street = sim.commitRoad(
          const [Vec2(200, 260), Vec2(40, 260)], RoadClass.street)!;
      // What a caller reads there: the ramp's deck, at the ground.
      final h = sim.deckHeightAt(ramp, const Vec2(0, 200))!;
      expect(h, closeTo(rolling(const Vec2(0, 200)), 1e-6));

      final quoted = sim.quoteMoveRoadEnd(street,
          atStart: false, to: const Vec2(0, 200), toHeightM: h,
          groundAt: rolling);
      expect(quoted.deck, isNull,
          reason: 'not a straight grade line between its end heights');
      final r = sim.moveRoadEnd(street,
          atStart: false, to: const Vec2(0, 200), toHeightM: h,
          groundAt: rolling);
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      final laid = sim.layout.roadById(r.roadId!)!;
      expect(laid.deck, isNull, reason: 'on the ground, where it was');
      expect(laid.controls.last.distanceTo(const Vec2(0, 200)), lessThan(1e-6));
      expect(
          sim.roadGraph
              .nodeNear(const Vec2(0, 200), withinM: 3)!
              .legRoadIds,
          containsAll([ramp, r.roadId!]),
          reason: 'it meets the ramp at its foot');
    });

    test('quoteMoveRoadEnd is what moveRoadEnd charges, and changes nothing',
        () {
      final sim = colony();
      final bridge =
          sim.buildRoad(acrossTheValley(), groundAt: valley).roadId!;
      final raised = sim
          .buildRoad(RoadBuildRequest(
              controls: const [Vec2(0, 300), Vec2(0, 700)],
              type: type('two-lane'),
              startElevationM: 12,
              endElevationM: 12))
          .roadId!;
      final street = sim.commitRoad(
          const [Vec2(-300, -300), Vec2(-300, 0)], RoadClass.street)!;
      for (final (id, atStart, to) in [
        (bridge, false, const Vec2(460, 0)),
        (raised, true, const Vec2(0, 250)),
        (street, false, const Vec2(-260, 60)),
      ]) {
        final rev = sim.roadsRevision;
        final funds = sim.funds;
        final roads = sim.layout.roads.length;
        final q = sim.quoteMoveRoadEnd(id,
            atStart: atStart, to: to, groundAt: valley);
        expect(sim.roadsRevision, rev, reason: 'a quote lays nothing');
        expect(sim.funds, funds);
        expect(sim.layout.roads.length, roads);
        final r =
            sim.moveRoadEnd(id, atStart: atStart, to: to, groundAt: valley);
        expect(r.quote.ok, isTrue, reason: r.quote.reason);
        expect(q.cost, greaterThan(0));
        expect(r.quote.cost, q.cost, reason: 'the quote is the bill');
        expect(sim.funds, closeTo(funds - q.cost, 1e-6));
        expect(r.quote.deck?.startM, q.deck?.startM);
        expect(r.quote.deck?.endM, q.deck?.endM);
      }
      expect(
          sim
              .quoteMoveRoadEnd('ghost', atStart: true, to: const Vec2(0, 0))
              .refusal,
          RoadRefusal.notFound);
    });

    test('a road that is gone cannot be adjusted', () {
      final sim = colony();
      final r = sim.moveRoadEnd('ghost', atStart: true, to: const Vec2(0, 0));
      expect(r.roadId, isNull);
      expect(r.quote.refusal, RoadRefusal.notFound);
    });

    test('a bridge a cell longer is charged the cell, not its premium', () {
      final sim = colony();
      final b = sim.buildRoad(acrossTheValley(), groundAt: valley);
      expect(b.quote.ok, isTrue, reason: b.quote.reason);
      // 200 m on the ground and 200 m of bridge over the valley.
      expect(b.quote.cost,
          closeTo(25 * 40 + 25 * 40 * RoadCosts.bridgeBuildMult, 1e-6));
      final longer = sim.moveRoadEnd('r0',
          atStart: false, to: const Vec2(408, 0), groundAt: valley);
      expect(longer.quote.ok, isTrue, reason: longer.quote.reason);
      expect(longer.quote.cost, closeTo(40, 1e-6), reason: 'one cell at grade');
      final funds = sim.funds;
      final shorter = sim.moveRoadEnd(longer.roadId!,
          atStart: false, to: const Vec2(392, 0), groundAt: valley);
      expect(shorter.quote.ok, isTrue, reason: shorter.quote.reason);
      expect(shorter.quote.cost, 0, reason: 'a shorter road is free');
      expect(sim.funds, funds);
      final deck = sim.layout.roadById(shorter.roadId!)!.deck!;
      expect(deck.structures.single.$1, closeTo(100, 1e-6));
      expect(deck.structures.single.$2, closeTo(300, 1e-6));
    });

    test('an end dragged back along a curve gives up the stretch behind it',
        () {
      final sim = colony();
      // A quarter circle of 100 m radius, as the layout keeps a curve: its
      // 2 m samples thinned to a control every ten metres or so.
      final arc = [
        for (var d = 0; d <= 90; d += 3)
          Vec2(100 * math.cos(d * math.pi / 180),
              100 * math.sin(d * math.pi / 180)),
      ];
      sim.commitRoad(arc, RoadClass.street);
      expect(sim.layout.roadById('r0')!.controls.length, greaterThan(8));
      final oldLen = sim.layout.roadIndex.byId('r0')!.lengthM;
      // The start circle dragged 25 m along the road.
      const a = 25 / 100;
      final r = sim.moveRoadEnd('r0',
          atStart: true, to: Vec2(100 * math.cos(a), 100 * math.sin(a)));
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      expect(r.quote.cost, 0, reason: 'shortened, not lengthened by a fold');
      final rec = sim.layout.roadIndex.byId(r.roadId!)!;
      expect(rec.lengthM, closeTo(oldLen - 25, 0.5));
      // One way round the curve, never back over itself.
      var prev = -1.0;
      for (final p in rec.samples) {
        final angle = math.atan2(p.n, p.e);
        expect(angle, greaterThanOrEqualTo(prev - 1e-9));
        prev = angle;
      }
      expect(math.atan2(rec.samples.first.n, rec.samples.first.e),
          closeTo(a, 1e-9));
    });

    test('the controls behind a dragged end go, at either end', () {
      final line = [for (var x = 0; x <= 100; x += 10) Vec2(x.toDouble(), 0)];
      List<double> east(List<Vec2> cs) => [for (final c in cs) c.e];
      // Back along it from the end: the controls it passed, and those
      // within a cell beyond, are dropped.
      expect(
          east(controlsWithMovedEnd(line,
              atStart: false, to: const Vec2(55, 0))),
          [0, 10, 20, 30, 40, 55]);
      expect(
          east(controlsWithMovedEnd(line,
              atStart: true, to: const Vec2(45, 0))),
          [45, 60, 70, 80, 90, 100]);
      // Off the end — longer — only the end moves.
      expect(
          east(controlsWithMovedEnd(line,
              atStart: false, to: const Vec2(120, 0))),
          [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 120]);
      expect(
          east(controlsWithMovedEnd(line,
              atStart: true, to: const Vec2(-20, 0))),
          [-20, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]);
      // Back along it and a little aside is still back along it: the
      // stretch behind goes rather than the road folding over it.
      expect(
          east(controlsWithMovedEnd(line,
              atStart: true, to: const Vec2(45, 6))),
          [45, 60, 70, 80, 90, 100]);
    });

    // A U, 40 m between its arms: the start nudged 30 m sideways lands
    // 10 m from the FAR arm, 250 m on round the road.
    const uBend = [
      Vec2(0, 0), Vec2(50, 0), Vec2(100, 0), Vec2(120, 20), //
      Vec2(100, 40), Vec2(50, 40), Vec2(0, 40),
    ];

    test('an end nudged near the far arm of a U only moves the end', () {
      List<(double, double)> pts(List<Vec2> cs) => [for (final c in cs) (c.e, c.n)];
      expect(
          pts(controlsWithMovedEnd(uBend,
              atStart: true, to: const Vec2(0, 30))),
          pts([const Vec2(0, 30), ...uBend.skip(1)]),
          reason: 'not the far arm\'s stub (0,30)-(0,40)');
      expect(
          pts(controlsWithMovedEnd(uBend,
              atStart: false, to: const Vec2(0, 10))),
          pts([...uBend.take(uBend.length - 1), const Vec2(0, 10)]));
    });

    test('a U adjusted near its own far arm keeps its length and its lots',
        () {
      final sim = colony();
      sim.commitRoad(uBend, RoadClass.street);
      final oldLen = sim.layout.roadIndex.byId('r0')!.lengthM;
      final lots = sim.layout.autoParcels.length;
      expect(lots, greaterThan(8));
      // Buildings along the far arm, 150 m and more round from the start.
      final far = [
        for (final p in sim.layout.autoParcels)
          if (p.centroid.n > 40) p,
      ];
      expect(far.length, greaterThanOrEqualTo(3));
      for (final lot in far) {
        sim.parcelBuildings[lot.id] = clinic;
      }
      final r = sim.moveRoadEnd('r0', atStart: true, to: const Vec2(0, 30));
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      final rec = sim.layout.roadIndex.byId(r.roadId!)!;
      expect(rec.lengthM, closeTo(oldLen, 40),
          reason: 'the end moved, not a 10 m stub left of the U');
      expect(rec.samples.first.n, closeTo(30, 1e-6));
      expect(sim.layout.autoParcels.length, greaterThanOrEqualTo(lots - 4));
      // The re-plat runs from the moved start, so a lot or two may fall
      // off the far end; the rest of the far arm's buildings are carried.
      final ids = {for (final p in sim.layout.parcels) p.id};
      final standing = [
        for (final id in sim.parcelBuildings.keys)
          if (ids.contains(id)) id,
      ];
      expect(standing.length, greaterThanOrEqualTo(far.length - 2),
          reason: 'the far arm\'s buildings keep their lots');
    });

    test('an end dragged back round a bend it doubles on gives up the bend',
        () {
      List<(double, double)> pts(List<Vec2> cs) =>
          [for (final c in cs) (c.e, c.n)];
      // The U's end back round the bend to its other arm: 180 m round the
      // road, past the arc an 89 m drag could span. The line is followed
      // on to it, not cut where the search's bound fell on the bend.
      expect(
          pts(controlsWithMovedEnd(uBend,
              atStart: false, to: const Vec2(80, 0))),
          pts(const [Vec2(0, 0), Vec2(50, 0), Vec2(80, 0)]),
          reason: 'not out to (100,0) and back');
      // 20 m off that arm: the nearest the road comes, not the bend.
      expect(
          pts(controlsWithMovedEnd(uBend,
              atStart: false, to: const Vec2(80, -20))),
          pts(const [Vec2(0, 0), Vec2(50, 0), Vec2(80, -20)]));
      // Three quarters of a circle, its end dragged back to the 30° point.
      final arc = [
        for (var d = 0; d <= 270; d += 15)
          Vec2(40 * math.cos(d * math.pi / 180),
              40 * math.sin(d * math.pi / 180)),
      ];
      final to = Vec2(40 * math.cos(math.pi / 6), 40 * math.sin(math.pi / 6));
      expect(pts(controlsWithMovedEnd(arc, atStart: false, to: to)),
          pts([arc[0], arc[1], to]));
    });

    test('a U re-laid back round its bend is trimmed, not folded', () {
      final sim = colony();
      sim.commitRoad(uBend, RoadClass.street);
      final r = sim.moveRoadEnd('r0', atStart: false, to: const Vec2(80, 0));
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      final rec = sim.layout.roadIndex.byId(r.roadId!)!;
      expect(rec.lengthM, closeTo(80, 1));
      for (final p in rec.samples) {
        expect(p.e, lessThanOrEqualTo(80 + 1e-6),
            reason: 'nothing runs out past its new end and back');
      }
    });

    // Every site the colony keys by lot names a lot that stands.
    void expectNoLostLots(CitySim sim) {
      final ids = {for (final p in sim.layout.parcels) p.id};
      for (final site in [
        ...sim.parcelBuildings.keys,
        ...sim.grownParcels.keys,
        ...sim.lotFires.keys,
        for (final s in sim.deliveries.keys)
          if (CitySim.cellOfSiteId(s) == null) s,
        for (final c in sim.craft) c.site,
        if (sim.landerPad != null) sim.landerPad!,
      ]) {
        expect(ids, contains(site));
      }
    }

    test('a road cut shorter tears down what stood on the lots it gave up',
        () {
      final sim = colony();
      sim.commitRoad(const [Vec2(0, 0), Vec2(0, 300)], RoadClass.street);
      final near = sim.layout.autoParcels.firstWhere((p) => p.centroid.n < 50);
      final far = [
        for (final p in sim.layout.autoParcels)
          if (p.centroid.n > 200) p,
      ];
      expect(far.length, greaterThanOrEqualTo(4));
      sim.parcelBuildings[near.id] = clinic;
      sim.parcelBuildings[far[0].id] = clinic;
      sim.grownParcels[far[1].id] = 1.5;
      sim.lotFires[far[2].id] = 0.4;
      final port = far[3].id;
      sim.deliveries[port] = [
        DeliverySchedule(resource: 'ore', intervalSec: 60, amount: 10),
      ];
      sim.craft.add(LandedCraft(site: port, padIndex: 0, isRelief: true));
      sim.landerPad = port;
      // A grid site is not a lot: nothing a road does touches it.
      final cell = CitySim.siteIdOfCell(5);
      sim.deliveries[cell] = [
        DeliverySchedule(resource: 'ore', intervalSec: 60, amount: 10),
      ];
      final r = sim.moveRoadEnd('r0', atStart: false, to: const Vec2(0, 100));
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      expectNoLostLots(sim);
      expect(sim.parcelBuildings, hasLength(1),
          reason: 'the near lot\'s building is carried, the far one torn down');
      expect(sim.grownParcels, isEmpty);
      expect(sim.lotFires, isEmpty);
      expect(sim.deliveries.keys, [cell]);
      expect(sim.craft, isEmpty);
      expect(sim.landerPad, isNull);
    });

    test('a road built over a lot tears down what stood on it', () {
      final sim = colony();
      sim.commitRoad(vertical, RoadClass.street);
      final lot = sim.layout.autoParcels.firstWhere(
          (p) => p.centroid.e > 0 && p.centroid.n.abs() < 150);
      final other = sim.layout.autoParcels.firstWhere(
          (p) => p.centroid.e < 0 && p.centroid.n < -200);
      sim.parcelBuildings[lot.id] = clinic;
      sim.parcelBuildings[other.id] = clinic;
      // Across the street and straight over the lot's middle.
      final c = lot.centroid;
      final r = sim.buildRoad(RoadBuildRequest(
          controls: [Vec2(-100, c.n), Vec2(100, c.n)],
          type: type('two-lane')));
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      expect(sim.layout.parcelAt(c), isNull, reason: 'its ground is road now');
      expectNoLostLots(sim);
      expect(sim.parcelBuildings, hasLength(1),
          reason: 'only the building on the lot the road took goes');
    });

    test('a street upgraded to a road that plats nothing loses its lots', () {
      final sim = colony()..ignoreUnlocks = true;
      sim.commitRoad(vertical, RoadClass.street);
      final lots = sim.layout.autoParcels.take(3).toList();
      sim.parcelBuildings[lots[0].id] = clinic;
      sim.grownParcels[lots[1].id] = 2.0;
      sim.lotFires[lots[2].id] = 0.3;
      final q = sim.upgradeRoad('r0', type('highway'));
      expect(q.ok, isTrue, reason: q.reason);
      expect(sim.layout.autoParcels, isEmpty, reason: 'an expressway plats none');
      expectNoLostLots(sim);
      expect(sim.parcelBuildings, isEmpty);
      expect(sim.grownParcels, isEmpty);
      expect(sim.lotFires, isEmpty);
    });

    test('a bridge drawn short of a street is surveyed on the line laid', () {
      final sim = colony();
      sim.commitRoad(vertical, RoadClass.street);
      final req = RoadBuildRequest(
          controls: const [Vec2(12, 0), Vec2(400, 0)],
          type: type('two-lane'),
          startHeightM: 0,
          endHeightM: 0);
      final quoted = sim.quoteRoad(req, groundAt: valley);
      final r = sim.buildRoad(req, groundAt: valley);
      expect(r.quote.ok, isTrue, reason: r.quote.reason);
      final road = sim.layout.roadById(r.roadId!)!;
      expect(road.controls.first.e, closeTo(0, 1e-9),
          reason: 'its start snapped back onto the street');
      expect(r.quote.lengthM, closeTo(400, 1e-6), reason: 'priced as laid');
      expect(quoted.cost, closeTo(r.quote.cost, 1e-9),
          reason: 'the preview is the bill');
      // The valley is 100 m to 300 m from the street, and so is the span.
      final span = road.deck!.structures.single;
      expect(span.$1, closeTo(100, 1e-6));
      expect(span.$2, closeTo(300, 1e-6));
      expect(sim.layout.roads.length, 3, reason: 'a T that cuts the street');
    });

    test('a raised end is built where it was drawn, not on the street below',
        () {
      final sim = colony();
      sim.commitRoad(horizontal, RoadClass.street);
      final up = sim.buildRoad(RoadBuildRequest(
          controls: const [Vec2(0, 300), Vec2(0, 10)],
          type: type('two-lane'),
          endElevationM: 12));
      expect(up.quote.ok, isTrue, reason: up.quote.reason);
      expect(sim.layout.roadById(up.roadId!)!.controls.last.n,
          closeTo(10, 1e-9));
      expect(sim.layout.roads.length, 2, reason: 'nothing joined, nothing cut');
      // At grade it lands on the street, and cuts it for the T.
      final down = sim.buildRoad(RoadBuildRequest(
          controls: const [Vec2(100, 300), Vec2(100, 10)],
          type: type('two-lane')));
      expect(sim.layout.roadById(down.roadId!)!.controls.last.n,
          closeTo(0, 1e-9));
      expect(sim.layout.roads.length, 4);
    });
  });

  test("the editor's ground radius grade-checks a road, and nothing else",
      () {
    // The editor hands commitRoad the ground as a RADIUS — six thousand
    // kilometres from the body's centre — which its grade check reads as
    // well as a height, since it compares only differences.
    final sim = colony();
    sim.commitRoad(horizontal, RoadClass.street,
        deck: const RoadDeck(startM: 0, endM: 0));
    final radius = sim.body.radius;
    expect(
        sim.commitRoad(vertical, RoadClass.street, groundAt: (_) => radius),
        isNotNull);
    expect(sim.layout.roads.length, 4,
        reason: 'the deck at grade meets the street: a junction');
    final pieces = sim.layout.roads.where((r) => r.deck != null).toList();
    expect(pieces, hasLength(2));
    for (final p in pieces) {
      expect(p.deck!.startOffsetM.abs(), lessThan(1e-6), reason: p.id);
      expect(p.deck!.endOffsetM.abs(), lessThan(1e-6), reason: p.id);
    }
    // The ground as a HEIGHT above the datum is what slices a deck.
    final other = colony();
    other.commitRoad(horizontal, RoadClass.street,
        deck: const RoadDeck(startM: 0, endM: 0));
    other.commitRoad(vertical, RoadClass.street, groundHeightAt: (_) => -1);
    expect(other.layout.roadById('r0x0')!.deck!.endOffsetM,
        closeTo(1, 1e-9));
    expect(other.layout.roadById('r0x1')!.deck!.startOffsetM,
        closeTo(1, 1e-9));
  });

  test("a deck's height is read at the nearest point of its road", () {
    final sim = colony();
    sim.commitRoad(const [Vec2(0, 0), Vec2(400, 0)], RoadClass.street,
        deck: const RoadDeck(
            startM: 0, endM: 12, endOffsetM: 12, structures: [(100, 400)]));
    expect(sim.deckHeightAt('r0', const Vec2(200, 30)), closeTo(6, 1e-9));
    expect(sim.deckHeightAt('r0', const Vec2(-50, 0)), closeTo(0, 1e-9));
    sim.commitRoad(const [Vec2(0, 500), Vec2(400, 500)], RoadClass.street);
    expect(sim.deckHeightAt('r1', const Vec2(200, 500)), isNull);
    expect(sim.deckHeightAt('ghost', const Vec2(0, 0)), isNull);
  });

  test('junction overrides: set, found near, replaced, removed', () {
    final sim = colony();
    final rev = sim.roadsRevision;
    sim.setJunctionOverride(
        const JunctionOverride(at: Vec2(100, 100), lights: true));
    expect(sim.roadsRevision, greaterThan(rev));
    expect(sim.junctionOverrideNear(const Vec2(103, 102))!.lights, isTrue);
    expect(sim.junctionOverrideNear(const Vec2(120, 100)), isNull);
    // The same junction said again a metre off: replaced, not doubled.
    sim.setJunctionOverride(
        const JunctionOverride(at: Vec2(101, 100), lights: false));
    expect(sim.junctionOverrides, hasLength(1));
    expect(sim.junctionOverrideNear(const Vec2(100, 100))!.lights, isFalse);
    // Saying nothing gives the junction back to the warrant.
    sim.setJunctionOverride(const JunctionOverride(at: Vec2(100, 100)));
    expect(sim.junctionOverrides, isEmpty);
  });

  group('the save', () {
    test('round-trips every road-tool attribute and the overrides', () {
      final sim = colony();
      sim.commitRoad(const [Vec2(0, 0), Vec2(400, 0)], RoadClass.streetOneWay,
          decoration: RoadDecoration.trees,
          deck: const RoadDeck(
              startM: 3,
              endM: -9,
              startOffsetM: 0.5,
              endOffsetM: -12,
              structures: [(0, 40)],
              tunnels: [(200, 400)]),
          reversed: true,
          name: 'Harbour Row');
      sim.setJunctionOverride(const JunctionOverride(
          at: Vec2(10, 20), lights: false, stopHeadings: [0.5, 2.0]));
      final back = CitySim.fromJson(sim.toJson(), bodies: bodies);
      final r = back.layout.roadById('r0')!;
      expect(r.roadClass, RoadClass.streetOneWay);
      expect(r.decoration, RoadDecoration.trees);
      expect(r.reversed, isTrue);
      expect(r.name, 'Harbour Row');
      final deck = r.deck!;
      expect(deck.startM, closeTo(3, 1e-9));
      expect(deck.endM, closeTo(-9, 1e-9));
      expect(deck.startOffsetM, closeTo(0.5, 1e-9));
      expect(deck.endOffsetM, closeTo(-12, 1e-9));
      expect(deck.structures.single.$2, closeTo(40, 1e-9));
      expect(deck.tunnels.single.$1, closeTo(200, 1e-9));
      expect(deck.tunnels.single.$2, closeTo(400, 1e-6));
      final o = back.junctionOverrideNear(const Vec2(10, 20))!;
      expect(o.lights, isFalse);
      expect(o.stopHeadings, [0.5, 2.0]);
      expect(back.roadsRevision, greaterThan(0));
    });

    test("a laid deck keeps its survey's length; an old save's deck has none",
        () {
      final sim = colony();
      final built = sim.buildRoad(RoadBuildRequest(
          controls: const [
            Vec2(0, 0),
            Vec2(72, 0),
            Vec2(85.5, 3.2),
            Vec2(76.5, 6.4),
          ],
          type: type('two-lane'),
          startElevationM: 12,
          endElevationM: 12));
      expect(built.roadId, isNotNull, reason: built.quote.reason);
      final deck = sim.layout.roadById(built.roadId!)!.deck!;
      expect(deck.rangeLengthM, closeTo(built.quote.lengthM, 1e-9));
      final json = sim.toJson();
      final saved = ((json['roads'] as List).single as Map)['deck'] as Map;
      expect(saved['l'], deck.rangeLengthM);
      final back = CitySim.fromJson(json, bodies: bodies);
      final r = back.layout.roadById(built.roadId!)!;
      expect(r.deck, deck);
      // Re-sampled from the save's decimated controls, the road comes out
      // a little another length; its end still stands on its piers.
      final rec = back.layout.roadIndex.byId(r.id)!;
      expect(
          CityLayout.levelOf(r.deck, rec.lengthM, rec.lengthM)!.offGround,
          isTrue);
      // A save from before the length was kept loads the deck as it was.
      saved.remove('l');
      final old = CitySim.fromJson(json, bodies: bodies)
          .layout
          .roadById(built.roadId!)!
          .deck!;
      expect(old.rangeLengthM, isNull);
      expect(old.structures, deck.structures);
      expect(old.startM, deck.startM);
      expect(old.endM, deck.endM);
    });

    test('a road that never used the tool saves as it always has', () {
      final sim = colony();
      sim.commitRoad(const [Vec2(0, 0), Vec2(400, 0)], RoadClass.street);
      final json = sim.toJson();
      final road = (json['roads'] as List).single as Map;
      for (final key in ['deco', 'deck', 'rev', 'name']) {
        expect(road.containsKey(key), isFalse, reason: key);
      }
      expect(json.containsKey('junctions'), isFalse);
      final back = CitySim.fromJson(json, bodies: bodies);
      final r = back.layout.roadById('r0')!;
      expect(r.decoration, RoadDecoration.none);
      expect(r.deck, isNull);
      expect(r.reversed, isFalse);
      expect(r.name, isNull);
      expect(back.junctionOverrides, isEmpty);
    });

    test('indices from a newer build load as something drawable', () {
      final sim = colony();
      sim.commitRoad(const [Vec2(0, 0), Vec2(400, 0)], RoadClass.street);
      final json = sim.toJson();
      final road = (json['roads'] as List).single as Map;
      road['class'] = 99;
      road['deco'] = 7;
      json['junctions'] = [
        {'at': 'garbage'},
        {
          'at': [1, 2],
          'lights': true
        },
      ];
      final back = CitySim.fromJson(json, bodies: bodies);
      expect(back.layout.roadById('r0')!.roadClass, RoadClass.street);
      expect(back.layout.roadById('r0')!.decoration, RoadDecoration.none);
      expect(back.junctionOverrides, hasLength(1));
    });
  });
}
