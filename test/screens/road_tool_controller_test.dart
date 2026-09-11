// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_build.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/road_snapper.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

/// The road tool as a player drives it — a click a stretch — against a
/// colony with no widget in sight: the chain, the three shapes, the
/// elevation, the snapping menu, the bill, Upgrade and its right-click, and
/// the info views' clicks.
void main() {
  CitySim colony({double funds = 1e6}) => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'tool',
      )..funds = funds;

  /// The road tool held with nothing to snap to unless a test asks: the
  /// points a test clicks are the points it means.
  CityEditController roadTool({RoadSnapOptions snap = RoadSnapOptions.off}) =>
      CityEditController()
        ..set(CityEditTool.roadSpline)
        ..snap = snap;

  const roadsOnly = RoadSnapOptions(
      roads: true, angles: false, zoningGrid: false, guidelines: false);

  RoadSpline road(CitySim city, String id) => city.layout.roadById(id)!;

  double headingDeg(Vec2 d) => math.atan2(d.e, d.n) * 180 / math.pi;

  group('Straight', () {
    test('a chain of clicks lays consecutive roads that share their nodes',
        () {
      final city = colony();
      final c = roadTool(snap: roadsOnly);
      c.clickAt(city, const Vec2(0, 0));
      expect(c.anchor?.point, const Vec2(0, 0));
      expect(city.layout.roads, isEmpty, reason: 'the first click is a start');

      c.clickAt(city, const Vec2(0, 120));
      final first = c.lastRoadId!;
      c.clickAt(city, const Vec2(120, 120));
      final second = c.lastRoadId!;
      expect(first, isNot(second));
      expect(city.layout.roads, hasLength(2));
      expect(c.anchor!.point.distanceTo(const Vec2(120, 120)), lessThan(1e-6),
          reason: 'the chain carries on from the end just built');

      // One node where the two meet, both roads' ends on it.
      final node = city.roadGraph.nodeNear(const Vec2(0, 120), withinM: 2)!;
      expect(node.legRoadIds, containsAll([first, second]));
    });

    test('the quote is the bill: the treasury is charged what it priced', () {
      final city = colony(funds: 10000);
      final c = roadTool();
      c.clickAt(city, const Vec2(0, 0));
      final preview = c.previewTo(city, const Vec2(0, 160))!;
      expect(preview.quote.ok, isTrue);
      c.clickAt(city, const Vec2(0, 160));
      final q = c.lastQuote!;
      expect(q.cost, closeTo(preview.quote.cost, 1e-9),
          reason: 'the hover priced the line the click laid');
      expect(q.cost,
          closeTo(RoadCosts.construction(c.roadType, lengthM: q.lengthM), 1e-6));
      expect(city.funds, closeTo(10000 - q.cost, 1e-6));
    });

    test('a refused stretch keeps the anchor and says why', () {
      final city = colony(funds: 0);
      final c = roadTool();
      c.clickAt(city, const Vec2(0, 0));
      c.clickAt(city, const Vec2(0, 120));
      expect(city.layout.roads, isEmpty);
      expect(c.blocked, contains('Not enough money'));
      expect(c.anchor?.point, const Vec2(0, 0),
          reason: 'the player tops up or re-aims; the start stays');
    });
  });

  test('Curved: the second click is the pull point, the third builds through '
      'it', () {
    final city = colony();
    final c = roadTool()..setMode(RoadToolMode.curved);
    c.clickAt(city, const Vec2(0, 0));
    c.clickAt(city, const Vec2(100, 100));
    expect(c.control, const Vec2(100, 100));
    expect(city.layout.roads, isEmpty, reason: 'the pull point builds nothing');
    c.clickAt(city, const Vec2(200, 0));
    expect(city.layout.roads, hasLength(1));
    expect(c.control, isNull);
    expect(c.anchor!.point.distanceTo(const Vec2(200, 0)), lessThan(1e-6));
    // A quadratic through (100, 100) peaks 50 m off its chord.
    final pts = road(city, c.lastRoadId!).sample(stepM: 2);
    final bulge = pts.map((p) => p.n).reduce(math.max);
    expect(bulge, closeTo(50, 3));
  });

  test('Freeform: each stretch leaves on the heading the last one ended on',
      () {
    final city = colony();
    final c = roadTool()..setMode(RoadToolMode.freeform);
    c.clickAt(city, const Vec2(0, 0));
    c.clickAt(city, const Vec2(0, 100));
    expect(c.anchor!.tangent!.distanceTo(const Vec2(0, 1)), lessThan(1e-6),
        reason: 'the first stretch is straight, heading north');
    c.clickAt(city, const Vec2(80, 180));
    final pts = road(city, c.lastRoadId!).sample(stepM: 2);
    expect(headingDeg(pts[1] - pts[0]).abs(), lessThan(8),
        reason: 'it leaves north, as the last stretch ended');
    expect(headingDeg(pts.last - pts[pts.length - 2]), closeTo(90, 8),
        reason: 'a quarter circle to a point 80 m east and 80 m on');
    expect(headingDeg(c.anchor!.tangent!), closeTo(90, 2),
        reason: 'the next stretch carries on east');
  });

  group('elevation', () {
    test('PAGE UP / PAGE DOWN step it, onto multiples of the step, clamped',
        () {
      final c = roadTool();
      expect(c.elevationM, 0);
      expect(c.elevationStepM, 12, reason: 'the default step');
      c.stepElevation(1);
      expect(c.elevationM, 12);
      for (var i = 0; i < 10; i++) {
        c.stepElevation(1);
      }
      expect(c.elevationM, 60, reason: 'a road stands at most 60 m up');
      expect(c.blocked, contains('Too high'));
      c.setElevationStep(3);
      c.stepElevation(-1);
      expect(c.elevationM, 57);
      c.setElevationStep(6);
      c.stepElevation(-1);
      expect(c.elevationM, 54, reason: 'onto a multiple of the step');
      for (var i = 0; i < 30; i++) {
        c.stepElevation(-1);
      }
      expect(c.elevationM, -36, reason: 'and at most 36 m down');
    });

    test('a gravel road cannot go under; picking one clamps the elevation', () {
      final c = roadTool();
      c.stepElevation(-1);
      expect(c.elevationM, -12);
      c.pickRoadType(RoadType.byId('gravel')!);
      expect(c.elevationM, 0, reason: 'clamped to what the new class allows');
      c.stepElevation(-1);
      expect(c.elevationM, 0);
      expect(c.blocked, 'Gravel roads cannot go underground');
    });

    test('a raised stretch stands on a deck, and the chain carries its height',
        () {
      final city = colony();
      final c = roadTool();
      c.stepElevation(1);
      c.clickAt(city, const Vec2(0, 0));
      c.clickAt(city, const Vec2(0, 200));
      final deck = road(city, c.lastRoadId!).deck!;
      expect(deck.startM, closeTo(12, 1e-6));
      expect(deck.endM, closeTo(12, 1e-6));
      expect(deck.structures, isNotEmpty, reason: 'on piers, 12 m up');
      expect(c.lastQuote!.cost,
          greaterThan(RoadCosts.construction(c.roadType, lengthM: 200) * 1.5),
          reason: 'a structure costs a multiple of the road at grade');
      expect(c.anchor!.heightM, closeTo(12, 1e-6));

      // Back down to the ground: the next stretch ramps from the deck.
      c.stepElevation(-1);
      c.clickAt(city, const Vec2(0, 400));
      final ramp = road(city, c.lastRoadId!).deck!;
      expect(ramp.startM, closeTo(12, 1e-6));
      expect(ramp.endM, closeTo(0, 1e-6));
    });
  });

  group('snapping', () {
    test('with Roads on, a click near a road end joins it; off, it stays put',
        () {
      final city = colony();
      final id = city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)],
          RoadClass.street)!;
      final on = roadTool(snap: roadsOnly)..clickAt(city, const Vec2(5, 205));
      expect(on.anchor!.point.distanceTo(const Vec2(0, 200)), lessThan(1e-6));
      expect(on.anchor!.roadId, id);
      expect(on.anchor!.tangent!.distanceTo(const Vec2(0, 1)), lessThan(1e-6),
          reason: 'leaving a road end, it carries the road on');

      final off = roadTool()..clickAt(city, const Vec2(5, 205));
      expect(off.anchor!.point, const Vec2(5, 205));
      expect(off.anchor!.roadId, isNull);
    });

    test('with Angles on, a near-round heading snaps to it', () {
      final city = colony();
      final c = roadTool(
          snap: const RoadSnapOptions(
              roads: false, angles: true, zoningGrid: false, guidelines: false));
      c.clickAt(city, const Vec2(0, 0));
      final p = c.previewTo(city, const Vec2(3, 100))!;
      expect(p.snap.kind, RoadSnapKind.angle);
      expect(p.line.last.e, closeTo(0, 1e-6), reason: 'straight north');
      expect(c.cursorSnap!.guides, isNotEmpty,
          reason: 'the ray it followed is drawn');

      c.setSnap(RoadSnapOptions.off);
      final free = c.previewTo(city, const Vec2(3, 100))!;
      expect(free.snap.kind, RoadSnapKind.free);
      expect(free.line.last, const Vec2(3, 100));
    });

    test('the zoning grid cuts a stretch into whole lots', () {
      final city = colony();
      final c = roadTool(
          snap: const RoadSnapOptions(
              roads: false, angles: false, zoningGrid: true, guidelines: false));
      c.clickAt(city, const Vec2(0, 0));
      final p = c.previewTo(city, const Vec2(0, 100))!;
      // Two corner clearances (12 m) and whole 24 m frontages.
      expect(p.quote.lengthM, closeTo(96, 0.5));
    });
  });

  test('the hover prices without telling anyone; a click tells everyone', () {
    final city = colony();
    final c = roadTool();
    var notified = 0;
    c.addListener(() => notified++);
    c.clickAt(city, const Vec2(0, 0));
    final afterClick = notified;
    expect(afterClick, greaterThan(0));
    for (var i = 1; i <= 20; i++) {
      c.previewTo(city, Vec2(0, 10.0 * i));
    }
    expect(notified, afterClick,
        reason: 'hover runs per mouse move: a rebuild each would stall it');
    expect(c.preview!.line.first, const Vec2(0, 0));
    expect(c.preview!.quote.lengthM, closeTo(200, 0.5));
  });

  group('right-click and Esc', () {
    test('a right-click steps back: the pull point first, then the chain', () {
      final city = colony();
      final c = roadTool()..setMode(RoadToolMode.curved);
      c.clickAt(city, const Vec2(0, 0));
      c.clickAt(city, const Vec2(50, 50));
      expect(c.rightClickAt(city, const Vec2(9, 9)), isTrue);
      expect(c.control, isNull);
      expect(c.anchor, isNotNull);
      expect(c.rightClickAt(city, const Vec2(9, 9)), isTrue);
      expect(c.anchor, isNull);
      expect(c.rightClickAt(city, const Vec2(9, 9)), isFalse,
          reason: 'nothing left to step back from');
    });

    test('Esc ends the chain', () {
      final city = colony();
      final c = roadTool()..clickAt(city, const Vec2(0, 0));
      expect(c.escape(), isTrue);
      expect(c.anchor, isNull);
      expect(c.escape(), isFalse);
    });
  });

  group('Upgrade', () {
    test('a click turns the road into the held type, and charges the '
        'difference; a downgrade is free', () {
      final city = colony(funds: 5000);
      final id =
          city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
      final c = roadTool()
        ..setMode(RoadToolMode.upgrade)
        ..pickRoadType(RoadType.byId('four-lane')!);
      final q = c.upgradeHover(city, const Vec2(3, 100))!;
      expect(c.upgradeRoadId, id);
      c.clickAt(city, const Vec2(3, 100));
      expect(road(city, id).roadClass, RoadClass.avenue);
      expect(c.lastQuote!.cost, closeTo(q.cost, 1e-9));
      expect(q.cost, closeTo((60 - 40) / 8 * 200, 1.0),
          reason: 'the price difference over 200 m');
      expect(city.funds, closeTo(5000 - q.cost, 1e-6));

      final before = city.funds;
      c.pickRoadType(RoadType.byId('two-lane')!);
      c.clickAt(city, const Vec2(3, 100));
      expect(road(city, id).roadClass, RoadClass.street);
      expect(city.funds, before, reason: 'a downgrade is not a refund');
    });

    test('a right-click reverses a one-way road; a two-way one says why not',
        () {
      final city = colony();
      final oneWay = city.commitRoad(
          const [Vec2(0, 0), Vec2(0, 200)], RoadClass.streetOneWay)!;
      city.commitRoad(const [Vec2(300, 0), Vec2(300, 200)], RoadClass.street);
      final c = roadTool()..setMode(RoadToolMode.upgrade);
      expect(c.rightClickAt(city, const Vec2(2, 100)), isTrue);
      expect(road(city, oneWay).reversed, isTrue);
      expect(c.rightClickAt(city, const Vec2(302, 100)), isFalse);
      expect(c.blocked, contains('one-way'));
    });

    test('a click on open ground says what the tool wants', () {
      final city = colony();
      final c = roadTool()..setMode(RoadToolMode.upgrade);
      c.clickAt(city, const Vec2(500, 500));
      expect(c.blocked, contains('Click a road'));
    });
  });

  group('info views', () {
    CitySim crossing() {
      final city = colony();
      city.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
      city.commitRoad(const [Vec2(0, -200), Vec2(0, 200)], RoadClass.street);
      return city;
    }

    test('Junctions: a click on the junction switches its lights', () {
      final city = crossing();
      final c = CityEditController()
        ..set(CityEditTool.traffic)
        ..setTrafficView(TrafficInfoView.junctions);
      JunctionPlan plan() => city.roadGraph.nodeNear(const Vec2(0, 0))!.plan;
      expect(plan().control, JunctionControl.stop,
          reason: 'two streets crossing: an all-way stop');
      expect(c.toggleJunctionAt(city, const Vec2(1, 1)), isTrue);
      expect(plan().lights, isTrue);
      expect(c.toggleJunctionAt(city, const Vec2(1, 1)), isTrue);
      expect(plan().lights, isFalse);
    });

    test('Junctions: a click out along a leg switches its stop sign', () {
      final city = crossing();
      final c = CityEditController()..set(CityEditTool.traffic);
      final node = city.roadGraph.nodeNear(const Vec2(0, 0))!;
      expect(node.plan.stopLegs, hasLength(4));
      expect(c.toggleJunctionAt(city, const Vec2(0, 15)), isTrue);
      final after = city.roadGraph.nodeNear(const Vec2(0, 0))!;
      expect(after.plan.stopLegs, hasLength(3));
      final north = [
        for (var i = 0; i < after.legs.length; i++)
          if (after.legs[i].heading.abs() < 0.2) i
      ];
      expect(after.plan.stopLegs.intersection(north.toSet()), isEmpty,
          reason: 'the northern leg no longer stops');
      // And back.
      c.toggleJunctionAt(city, const Vec2(0, 15));
      expect(city.roadGraph.nodeNear(const Vec2(0, 0))!.plan.stopLegs,
          hasLength(4));
    });

    test('Junctions: with the lights on, a leg has no stop sign to switch', () {
      final city = crossing();
      final c = CityEditController()..set(CityEditTool.traffic);
      c.toggleJunctionAt(city, const Vec2(0, 0));
      expect(c.toggleJunctionAt(city, const Vec2(0, 15)), isFalse);
      expect(c.blocked, contains('lights off'));
    });

    test('Adjust: an end dragged re-lays the road there, and the selection '
        'follows it; a rename names every piece', () {
      final city = colony(funds: 5000);
      final id =
          city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
      final c = CityEditController()
        ..set(CityEditTool.traffic)
        ..setTrafficView(TrafficInfoView.adjust)
        ..selectRoad(id);
      final r =
          c.moveSelectedEnd(city, atStart: false, to: const Vec2(0, 260))!;
      expect(r.roadId, isNotNull);
      final moved = road(city, c.selectedRoadId!);
      expect(moved.controls.last.distanceTo(const Vec2(0, 260)), lessThan(1));
      expect(city.funds, closeTo(5000 - 60 / 8 * 40, 1.0),
          reason: 'charged for the 60 m added');

      expect(c.renameSelected(city, '  Harbour Road '), isTrue);
      expect(city.roadNameOf(c.selectedRoadId!), 'Harbour Road');
      expect(c.renameSelected(city, ''), isTrue);
      expect(city.roadNameOf(c.selectedRoadId!), isNot('Harbour Road'),
          reason: 'blank restores the generated name');
    });

    test('picking another tool drops the road being drawn', () {
      final city = colony();
      final c = roadTool()..clickAt(city, const Vec2(0, 0));
      c.set(CityEditTool.zone);
      expect(c.anchor, isNull);
    });
  });

  group('where a road meets another, it meets it at its level', () {
    /// A dip 5 m deep between n = 400 and n = 700 — gentle enough for a
    /// street to follow — and flat ground everywhere else.
    double dip(Vec2 p) => p.n > 400 && p.n < 700
        ? -5 * math.sin(math.pi * (p.n - 400) / 300)
        : 0;

    RoadBuildRequest raised(List<Vec2> controls,
            {double start = 12, double end = 12}) =>
        RoadBuildRequest(
          controls: controls,
          type: RoadType.byId('two-lane')!,
          startElevationM: start,
          endElevationM: end,
        );

    test('a ramp brought back to the ground ends the deck: the next stretch '
        'follows the ground, dip and all', () {
      final city = colony();
      final c = roadTool()..stepElevation(1);
      c.clickAt(city, const Vec2(0, 0), ground: dip);
      c.clickAt(city, const Vec2(0, 200), ground: dip);
      c.stepElevation(-1);
      expect(c.elevationM, 0, reason: 'the bar reads Ground');
      c.clickAt(city, const Vec2(0, 400), ground: dip);
      expect(road(city, c.lastRoadId!).deck!.endAtGrade, isTrue);
      expect(c.anchor!.heightM, isNull,
          reason: 'nothing raised to carry on from the foot of a ramp');
      c.clickAt(city, const Vec2(0, 700), ground: dip);
      expect(c.lastQuote!.ok, isTrue, reason: c.lastQuote!.reason);
      expect(road(city, c.lastRoadId!).deck, isNull,
          reason: 'laid on the ground, not a deck on piers over the dip');
      expect(c.lastQuote!.structureM, 0);
    });

    test('a road started on the ground end of a ramp is laid on the ground',
        () {
      final city = colony();
      final ramp = city
          .buildRoad(raised(const [Vec2(0, 200), Vec2(0, 400)], end: 0),
              groundAt: dip)
          .roadId!;
      expect(road(city, ramp).deck!.endAtGrade, isTrue);
      final c = roadTool(snap: roadsOnly);
      c.clickAt(city, const Vec2(3, 402), ground: dip);
      expect(c.anchor!.roadId, ramp);
      expect(c.anchor!.heightM, isNull);
      c.clickAt(city, const Vec2(0, 700), ground: dip);
      expect(road(city, c.lastRoadId!).deck, isNull);
    });

    test('an end snapped onto a street comes down to it, and joins it', () {
      final city = colony();
      city.commitRoad(
          const [Vec2(-200, 300), Vec2(200, 300)], RoadClass.street);
      final c = roadTool(snap: roadsOnly)..stepElevation(1);
      c.clickAt(city, const Vec2(0, 0));
      c.clickAt(city, const Vec2(2, 301));
      expect(c.lastQuote!.ok, isTrue, reason: c.lastQuote!.reason);
      final deck = road(city, c.lastRoadId!).deck!;
      expect(deck.startM, closeTo(12, 1e-6), reason: 'raised where it began');
      expect(deck.endM, closeTo(0, 1e-6), reason: 'at the street it joins');
      final node = city.roadGraph.nodeNear(const Vec2(2, 300), withinM: 3)!;
      expect(node.isJunction, isTrue,
          reason: 'the street cut, three legs meeting — not a stub in the '
              'air over it');
      expect(c.anchor!.heightM, isNull);
    });

    test('a road started on a street leaves it from the street', () {
      final city = colony();
      city.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
      final c = roadTool(snap: roadsOnly)..stepElevation(1);
      c.clickAt(city, const Vec2(1, 2));
      expect(c.anchor!.elevationM, 0);
      expect(c.anchor!.heightM, isNull);
      c.clickAt(city, const Vec2(0, 300));
      expect(c.lastQuote!.ok, isTrue, reason: c.lastQuote!.reason);
      final deck = road(city, c.lastRoadId!).deck!;
      expect(deck.startAtGrade, isTrue);
      expect(deck.endM, closeTo(12, 1e-6));
      expect(
          city.roadGraph.nodeNear(const Vec2(1, 0), withinM: 3)!.isJunction,
          isTrue);
    });

    test('an end snapped onto a viaduct meets its deck', () {
      final city = colony();
      city.buildRoad(raised(const [Vec2(-200, 300), Vec2(200, 300)]));
      final c = roadTool(snap: roadsOnly);
      c.clickAt(city, const Vec2(0, 0));
      c.clickAt(city, const Vec2(2, 301));
      expect(c.lastQuote!.ok, isTrue, reason: c.lastQuote!.reason);
      expect(road(city, c.lastRoadId!).deck!.endM, closeTo(12, 1e-6));
    });
  });

  group('the info views read what they draw', () {
    test('Junctions: from a district zoom a click on a stop sign switches '
        'the stop; only a click on the disc switches the lights', () {
      final city = colony();
      city.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
      city.commitRoad(const [Vec2(0, -200), Vec2(0, 200)], RoadClass.street);
      final c = CityEditController()..set(CityEditTool.traffic);
      const pxM = 3.0;
      final out = JunctionMarks.stopOutM(pxM);
      expect(out - JunctionMarks.stopRadiusM(pxM),
          greaterThanOrEqualTo(JunctionMarks.ringRadiusM(pxM)),
          reason: 'the stop sign stands clear of the junction disc');
      expect(c.toggleJunctionAt(city, Vec2(0, out), pxM: pxM), isTrue);
      var plan = city.roadGraph.nodeNear(const Vec2(0, 0))!.plan;
      expect(plan.lights, isFalse, reason: 'the lights were not touched');
      expect(plan.stopLegs, hasLength(3),
          reason: 'the north leg stops no more');
      expect(
          c.toggleJunctionAt(
              city, Vec2(0, JunctionMarks.ringRadiusM(pxM) * 0.8),
              pxM: pxM),
          isTrue);
      plan = city.roadGraph.nodeNear(const Vec2(0, 0))!.plan;
      expect(plan.lights, isTrue, reason: 'on the disc, the lights');
    });

    test('Adjust: dropped beside a street the end lands on it, and the drag '
        'priced exactly what letting go charges', () {
      final city = colony(funds: 5000);
      final id =
          city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
      city.commitRoad(
          const [Vec2(-200, 300), Vec2(200, 300)], RoadClass.street);
      final c = CityEditController()
        ..set(CityEditTool.traffic)
        ..setTrafficView(TrafficInfoView.adjust)
        ..selectRoad(id);
      final plan =
          c.previewMoveEnd(city, atStart: false, to: const Vec2(0, 288))!;
      expect(c.movePreview, same(plan));
      expect(plan.end.distanceTo(const Vec2(0, 300)), lessThan(1e-6),
          reason: 'on the street 12 m on, not 12 m short of it');
      expect(plan.controls.last.distanceTo(const Vec2(0, 300)), lessThan(1e-6));
      expect(plan.quote.ok, isTrue, reason: plan.quote.reason);
      final before = city.funds;
      final r =
          c.moveSelectedEnd(city, atStart: false, to: const Vec2(0, 288))!;
      expect(r.roadId, isNotNull, reason: r.quote.reason);
      expect(r.quote.cost, closeTo(plan.quote.cost, 1e-9),
          reason: 'the bill is the preview');
      expect(city.funds, closeTo(before - plan.quote.cost, 1e-6));
      expect(c.movePreview, isNull, reason: 'let go: nothing is dragged');
      expect(
          city.roadGraph.nodeNear(const Vec2(0, 300), withinM: 3)!.isJunction,
          isTrue);
    });

    test("Adjust: a raised road's end dropped on a street comes down to "
        'meet it', () {
      final city = colony();
      final id = city
          .buildRoad(RoadBuildRequest(
            controls: const [Vec2(0, 0), Vec2(0, 200)],
            type: RoadType.byId('two-lane')!,
            startElevationM: 12,
            endElevationM: 12,
          ))
          .roadId!;
      city.commitRoad(
          const [Vec2(-200, 400), Vec2(200, 400)], RoadClass.street);
      final c = CityEditController()
        ..set(CityEditTool.traffic)
        ..setTrafficView(TrafficInfoView.adjust)
        ..selectRoad(id);
      final plan =
          c.previewMoveEnd(city, atStart: false, to: const Vec2(1, 401))!;
      expect(plan.quote.deck!.startM, closeTo(12, 1e-6),
          reason: 'the end left alone keeps its height');
      expect(plan.quote.deck!.endM, closeTo(0, 1e-6),
          reason: 'the moved end at the street');
      final r =
          c.moveSelectedEnd(city, atStart: false, to: const Vec2(1, 401))!;
      expect(r.roadId, isNotNull, reason: r.quote.reason);
      expect(road(city, c.selectedRoadId!).deck!.endAtGrade, isTrue);
      expect(
          city.roadGraph.nodeNear(const Vec2(1, 400), withinM: 3)!.isJunction,
          isTrue);
    });

    test('Adjust: a road on the ground dropped over a tunnel it cannot see '
        'stays on the ground, and the drag priced what letting go charges',
        () {
      // Rolling ground, which a street follows and a deck would be cut,
      // piered and tunnelled through.
      double rolling(Vec2 p) =>
          3 * math.sin(p.n / 40) + 2 * math.sin(p.e / 35);
      final city = colony();
      // A tunnel 12 m down, ending under the field at (100, 300).
      final tunnel = city
          .buildRoad(
              RoadBuildRequest(
                controls: const [Vec2(100, -100), Vec2(100, 300)],
                type: RoadType.byId('two-lane')!,
                startElevationM: -12,
                endElevationM: -12,
              ),
              groundAt: rolling)
          .roadId!;
      expect(road(city, tunnel).deck!.inTunnelAt(0), isTrue);
      final id = city
          .buildRoad(
              RoadBuildRequest(
                controls: const [Vec2(0, 0), Vec2(0, 200)],
                type: RoadType.byId('one-way')!,
              ),
              groundAt: rolling)
          .roadId!;
      expect(road(city, id).deck, isNull);
      expect(city.reverseRoad(id), isTrue);
      final c = CityEditController()
        ..set(CityEditTool.traffic)
        ..setTrafficView(TrafficInfoView.adjust)
        ..selectRoad(id);

      // Let go 9 m from the tunnel's end, over it.
      const to = Vec2(94, 293);
      final plan =
          c.previewMoveEnd(city, atStart: false, to: to, ground: rolling)!;
      expect(plan.joinRoadId, isNull,
          reason: 'the tunnel is not there to meet from the ground');
      expect(plan.end, to);
      expect(plan.quote.ok, isTrue, reason: plan.quote.reason);
      expect(plan.quote.deck, isNull,
          reason: 'no lifts: drawn on the ground, not a ramp into the tunnel');
      expect(plan.quote.structureM + plan.quote.tunnelM, 0);
      expect(
          plan.quote.cost,
          city
              .quoteMoveRoadEnd(id, atStart: false, to: to, groundAt: rolling)
              .cost,
          reason: 'the preview is the domain\'s own quote');

      final before = city.funds;
      final r =
          c.moveSelectedEnd(city, atStart: false, to: to, ground: rolling)!;
      expect(r.roadId, isNotNull, reason: r.quote.reason);
      expect(r.quote.cost, plan.quote.cost, reason: 'the bill is the preview');
      expect(city.funds, closeTo(before - plan.quote.cost, 1e-6));
      final laid = road(city, c.selectedRoadId!);
      expect(laid.deck, isNull, reason: 're-laid on the ground');
      expect(laid.reversed, isTrue, reason: 'still one way, the same way');
      expect(laid.controls.last.distanceTo(to), lessThan(1e-6));
      expect(road(city, tunnel).deck!.tunnels, isNotEmpty,
          reason: 'the tunnel is left as it was');
    });

    test('Draw: an end on the ground passes over a tunnel it cannot see; '
        'one laid below the ground lands on it', () {
      double rolling(Vec2 p) =>
          3 * math.sin(p.n / 40) + 2 * math.sin(p.e / 35);
      final city = colony();
      // A tunnel 12 m down from end to end, which the road view shows only
      // with the tool below the ground.
      final tunnel = city
          .buildRoad(
              RoadBuildRequest(
                controls: const [Vec2(100, -100), Vec2(100, 300)],
                type: RoadType.byId('two-lane')!,
                startElevationM: -12,
                endElevationM: -12,
              ),
              groundAt: rolling)
          .roadId!;
      expect(road(city, tunnel).deck!.inTunnelAt(0), isTrue);
      final street = city.commitRoad(
          const [Vec2(-200, 0), Vec2(-100, 0)], RoadClass.street)!;
      final c = CityEditController();
      // 6 m from its end, and 4 m off its middle: both within reach.
      const nearEnd = Vec2(96, 296), overIt = Vec2(104, 100);

      expect(c.elevationM, 0);
      for (final at in const [nearEnd, overIt]) {
        final s = c.snapCursor(city, at);
        expect(s.roadId, isNull,
            reason: 'at ground level $at landed on ${s.roadId} (${s.kind})');
      }
      expect(c.snapCursor(city, const Vec2(-150, 4)).roadId, street,
          reason: 'a road on the ground is still landed on');

      c.elevationM = -12;
      expect(c.snapCursor(city, nearEnd).kind, RoadSnapKind.roadEnd);
      expect(c.snapCursor(city, nearEnd).roadId, tunnel);
      expect(c.snapCursor(city, overIt).roadId, tunnel,
          reason: 'from below the ground the tunnel is there to meet');
    });
  });

  test('the dev hook applies its settings through the same calls', () {
    final c = roadTool();
    c.applyToolParams({
      'mode': 'freeform',
      'type': 'four-lane',
      'step': '6',
      'elev': 'up',
      'snap': 'roads,grid',
      'view': 'junctions',
    });
    expect(c.mode, RoadToolMode.freeform);
    expect(c.roadType.id, 'four-lane');
    expect(c.elevationStepM, 6);
    expect(c.elevationM, 6);
    expect(c.snap.roads && c.snap.zoningGrid, isTrue);
    expect(c.snap.angles || c.snap.guidelines, isFalse);
    expect(c.trafficView, TrafficInfoView.junctions);
    c.applyToolParams({'type': 'highway'}, unlocked: (_) => false);
    expect(c.roadType.id, 'four-lane', reason: 'a locked type is not held');
    expect(c.blocked, 'Opens at 200 population');
    final s = c.roadToolStatus();
    expect(s['mode'], 'freeform');
    expect(s['snap'], ['roads', 'grid']);
  });
}
