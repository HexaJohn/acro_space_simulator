// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/trail_capture.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/trails/trail_field.dart';
import 'package:acro_space_simulator/domain/colony/city/trails/trail_network.dart';
import 'package:acro_space_simulator/domain/colony/city/trails/trail_promotion.dart';
import 'package:acro_space_simulator/domain/colony/city/trails/trail_router.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';

/// docs/plans/desire-paths.md Â§7's gates for phase 1.
void main() {
  TrailField flat(int cols, int rows) {
    final f = TrailField(originE: 0, originN: 0, cols: cols, rows: rows);
    f.fillHeights((e, n) => 0);
    return f;
  }

  test('a trail goes round a hill, not over it', () {
    final f = TrailField(originE: 0, originN: 0, cols: 80, rows: 60);
    // A 60 m hill, 120 m across, straight between the two ends.
    f.fillHeights((e, n) {
      final d2 = math.pow(e - 400, 2) + math.pow(n - 300, 2);
      return 60 * math.exp(-d2 / (2 * 60.0 * 60.0));
    });
    final router = TrailRouter(f);
    final r = router.route(f.cellAt(100, 300), f.cellAt(700, 300))!;
    var top = 0.0;
    for (final i in r.cells) {
      top = math.max(top, f.height[i]);
    }
    expect(top, lessThan(20), reason: 'the route climbs $top m of the hill');
    expect(r.lengthM, greaterThan(600));
    expect(r.timeS, greaterThan(r.lengthM / kTrailRawMps * 0.99));
  });

  test('ground too steep to climb cannot be crossed', () {
    final f = TrailField(originE: 0, originN: 0, cols: 40, rows: 10);
    // A 30 m cliff across the whole field at e = 200.
    f.fillHeights((e, n) => e < 200 ? 0 : 30);
    final router = TrailRouter(f);
    expect(router.route(f.cellAt(50, 50), f.cellAt(350, 50)), isNull);
    expect(router.reach(f.cellAt(50, 50))[f.cellAt(350, 50)], 0);
  });

  test('two homes commuting to one site merge onto one trunk', () {
    final f = flat(120, 80);
    final router = TrailRouter(f);
    // Two homes 100 m apart, a workplace 1 km off: two straight lines would
    // be a V; the worn ground pulls them into a Y.
    final a = f.cellAt(105, 355), b = f.cellAt(105, 455), work = f.cellAt(1105, 405);
    final first = router.route(a, work)!.cells.length +
        router.route(b, work)!.cells.length;
    for (var k = 0; k < 200; k++) {
      f.lay(router.route(k.isEven ? a : b, work)!.cells);
    }
    var beaten = 0;
    for (var i = 0; i < f.length; i++) {
      if (f.wear[i] > 0.5) beaten++;
    }
    expect(beaten, lessThan(first * 0.85),
        reason: '$beaten cells beaten against $first for two straight lines');
    // And the trail is quicker than the ground it was worn into.
    final worn = router.route(a, work)!;
    expect(worn.timeS, lessThan(worn.lengthM / kTrailRawMps * 0.8));
  });

  test('an unused trail fades', () {
    final f = flat(30, 3);
    final r = TrailRouter(f).route(f.cellAt(5, 15), f.cellAt(295, 15))!;
    for (var k = 0; k < 30; k++) {
      f.lay(r.cells);
    }
    expect(f.wear[r.cells[5]], greaterThan(0.9));
    for (var t = 0; t < 2 * 86400; t += 30) {
      f.decay(30);
    }
    expect(f.wear[r.cells[5]], lessThan(0.1));
  });

  test('a beaten run is read off its route as one simplified road', () {
    final f = TrailField(originE: 0, originN: 0, cols: 60, rows: 10);
    // Flat, with a 30% ramp halfway: a rover's, not a dirt road's.
    f.fillHeights(
        (e, n) => e < 300 ? 0 : (e < 330 ? (e - 300) * 0.3 : 9.0),
        stride: 1);
    final router = TrailRouter(f);
    final r = router.route(f.cellAt(5, 45), f.cellAt(595, 45))!;
    // Beaten end to end, then the same route again: one road asked for.
    for (var k = 0; k < 12; k++) {
      f.lay(r.cells);
    }
    final runs = beatenRuns(f, [r, r]);
    // Two runs either side of the step; each a straight line, so two points.
    expect(runs, hasLength(2));
    for (final run in runs) {
      expect(run, hasLength(2));
      expect(run.first.distanceTo(run.last), greaterThan(kTrailRoadMinM));
    }
    // Barely worn: nothing yet.
    final g = flat(60, 10);
    final r2 = TrailRouter(g).route(g.cellAt(5, 45), g.cellAt(595, 45))!;
    g.lay(r2.cells);
    expect(beatenRuns(g, [r2]), isEmpty);
  });

  test('a lot off the road is served by open ground while that is legal', () {
    final city = foundFlat(id: 'trails-serve');
    final lot = city.layout.addManualParcel(const [
      Vec2(200, 200),
      Vec2(260, 200),
      Vec2(260, 260),
      Vec2(200, 260),
    ])!;
    expect(city.parcelNetwork().lotServed(lot.id), isFalse);
    city.trails = TrailNetwork();
    city.syncTrails(0);
    expect(city.parcelNetwork().lotServed(lot.id), isTrue);
    city.laws.add(Law.offRoadBan);
    expect(city.offRoadLegal, isFalse);
    expect(city.parcelNetwork().lotServed(lot.id), isFalse);
  });

  group('a roadless starter colony', () {
    late CitySim city;
    setUpAll(() {
      city = quiet(CityStarterKit.found(
        bodies: fixtureBodies,
        config: const CityConfig(bodyId: 'moon', gridSize: 20),
        start: CityStart.relaxed,
        agentTraffic: true,
        roads: false,
      ));
    });

    test('has no road, and every site works', () {
      expect(city.layout.roads, isEmpty);
      final net = city.parcelNetwork();
      for (final (p, spec) in city.parcelBuiltLots()) {
        expect(net.lotServed(p.id), isTrue, reason: '${spec.type} cut off');
      }
    });

    test('lives and wears its trails', () {
      final pop0 = city.population;
      for (var s = 0; s < 4 * 3600 * 2; s++) {
        city.advance(0.5);
      }
      final legs = city.agents.commutes!.offRoadTrips;
      expect(legs, greaterThan(20), reason: 'off-road legs taken');
      expect(city.population, greaterThanOrEqualTo(math.min(6, pop0)));
      final f = city.trails!.field!;
      var worn = 0;
      for (var i = 0; i < f.length; i++) {
        if (f.wear[i] > 0.3) worn++;
      }
      expect(worn, greaterThan(30), reason: 'cells worn into a trail');
    });

    test('hands the scene its trails on the ground, and its rovers', () {
      final r = city.body.radius;
      TrailCapture.holdMs = 0;
      final frame = TrailCapture.frameFor(city, 'moon',
          groundFor: (key, local) => r + 2,
          dirOf: (local) =>
              city.localToBodyFixed(local, bodyRadiusM: r).normalized)!;
      expect(frame.ribbons.points, isNotEmpty);
      for (final pts in frame.ribbons.points) {
        for (var k = 0; k < pts.length; k += 3) {
          final len = math.sqrt(
              pts[k] * pts[k] + pts[k + 1] * pts[k + 1] + pts[k + 2] * pts[k + 2]);
          expect(len, closeTo(r + 2, 0.01), reason: 'on the ground');
        }
      }
      // Unchanged wear: the same ribbons, so the scene keeps its mesh.
      final again = TrailCapture.frameFor(city, 'moon',
          groundFor: (key, local) => r + 2,
          dirOf: (local) =>
              city.localToBodyFixed(local, bodyRadiusM: r).normalized)!;
      expect(identical(again.ribbons, frame.ribbons), isTrue);
      // A leg set off now is a rover on the way.
      final net = city.trails!;
      final route = net.takenRoutes.last;
      net.lay(route, startUs: city.agents.timeUs);
      final withRover = TrailCapture.frameFor(city, 'moon',
          groundFor: (key, local) => r + 2,
          dirOf: (local) =>
              city.localToBodyFixed(local, bodyRadiusM: r).normalized)!;
      expect(withRover.rovers.length, greaterThanOrEqualTo(6));
    });

    test('grades a dirt road along its most beaten trail', () {
      for (var s = 0; s < 8 * 3600 * 2 && city.trails!.roadsLaid == 0; s++) {
        city.advance(0.5);
      }
      expect(city.trails!.roadsLaid, greaterThan(0));
      final dirt = city.layout.roads.where((r) => r.roadClass == RoadClass.path);
      expect(dirt, isNotEmpty);
      // Still served, and still alive.
      final net = city.parcelNetwork();
      for (final (p, spec) in city.parcelBuiltLots()) {
        expect(net.lotServed(p.id), isTrue, reason: '${spec.type} cut off');
      }
      expect(city.population, greaterThanOrEqualTo(5));
    });

    test('keeps its trails through a save', () {
      final j = jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>;
      final back = CitySim.fromJson(j, bodies: fixtureBodies);
      final a = city.trails!.field!, b = back.trails!.field!;
      expect(b.cols, a.cols);
      expect(b.originE, a.originE);
      var diff = 0.0;
      for (var i = 0; i < a.length; i++) {
        diff = math.max(diff, (a.wear[i] - b.wear[i]).abs());
      }
      expect(diff, lessThan(0.002));
    });
  });
}
