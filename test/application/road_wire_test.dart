// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// The road tool's roads on the wire: a road's id and dressing, its deck as
/// a lift per point over the drape the capture already sampled, a reversed
/// one-way road flipped so first-to-last is still the way traffic runs, the
/// colony's roads revision, and the junction overrides on the ground.
void main() {
  CitySim colony(RoadSpline road) {
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'roads',
    );
    city.layout.addRoad(road);
    return city;
  }

  WorldSnapshot capture(CitySim city) => WorldSnapshot.capture(
        0,
        InMemoryVesselRepository(const []),
        system: SampleWorld.realSystem(),
        cities: InMemoryCityRepository([city]),
      );

  const controls = [Vec2(0, 0), Vec2(40, 120), Vec2(-20, 260)];

  RoadSpline spline({
    RoadClass cls = RoadClass.streetOneWay,
    RoadDeck? deck,
    bool reversed = false,
    RoadDecoration decoration = RoadDecoration.none,
    List<(double, double)> bridges = const [],
    double? hw0,
    double? hw1,
  }) =>
      RoadSpline(
        id: 'main',
        roadClass: cls,
        controls: controls,
        deck: deck,
        reversed: reversed,
        decoration: decoration,
        bridges: bridges,
        startHalfWidthM: hw0,
        endHalfWidthM: hw1,
      );

  final earthRadius = SampleWorld.realSystem()
      .all
      .firstWhere((b) => b.id.value == 'earth')
      .radius;

  /// The plan arc of the capture's own 6 m samples, and their total.
  (List<double>, double) arcOf(RoadSpline road) {
    final pts = road.sample(stepM: 6);
    final arc = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      arc.add(arc.last + pts[i].distanceTo(pts[i - 1]));
    }
    return (arc, arc.last);
  }

  double lengthOf(List<double> p, int i) =>
      math.sqrt(p[3 * i] * p[3 * i] +
          p[3 * i + 1] * p[3 * i + 1] +
          p[3 * i + 2] * p[3 * i + 2]);

  test('a road carries its id and decoration, and on the ground no lifts',
      () {
    final r = capture(colony(
            spline(cls: RoadClass.avenue, decoration: RoadDecoration.trees)))
        .roads
        .single;
    expect(r.id, 'main');
    expect(r.decoration, RoadDecoration.trees.index);
    expect(r.lifts, isEmpty);
  });

  test('a raised road carries its deck above the drape, point by point', () {
    // The drape first, to put the deck a known height over its start.
    final draped = capture(colony(spline())).roads.single;
    final groundM = lengthOf(draped.points, 0) - earthRadius;
    final deck = RoadDeck(startM: groundM + 12, endM: groundM + 24);
    final raised = capture(colony(spline(deck: deck))).roads.single;

    final n = raised.points.length ~/ 3;
    expect(raised.lifts, hasLength(n));
    // The points stay on the drape: the lift rides beside them.
    expect(raised.points, draped.points);
    final (arc, lengthM) = arcOf(spline());
    for (var i = 0; i < n; i++) {
      // The deck's radius less the drape's radius at that point.
      final want = earthRadius +
          deck.heightAt(arc[i], lengthM) -
          lengthOf(draped.points, i);
      expect(raised.lifts[i], closeTo(want, 0.02), reason: 'point $i');
    }
    expect(raised.lifts.first, closeTo(12, 0.02));
  });

  test('a reversed one-way road goes out flipped', () {
    final (_, lengthM) = arcOf(spline());
    final draped = capture(colony(spline())).roads.single;
    final groundM = lengthOf(draped.points, 0) - earthRadius;
    final deck = RoadDeck(startM: groundM + 6, endM: groundM + 30);
    final fwd = capture(colony(spline(
            deck: deck, bridges: const [(10, 30)], hw0: 3, hw1: 5)))
        .roads
        .single;
    final rev = capture(colony(spline(
            deck: deck,
            bridges: const [(10, 30)],
            hw0: 3,
            hw1: 5,
            reversed: true)))
        .roads
        .single;

    final n = fwd.points.length ~/ 3;
    expect(rev.points.length, fwd.points.length);
    for (var k = 0; k < n; k++) {
      final j = n - 1 - k;
      expect([rev.points[3 * k], rev.points[3 * k + 1], rev.points[3 * k + 2]],
          [fwd.points[3 * j], fwd.points[3 * j + 1], fwd.points[3 * j + 2]]);
      expect(rev.lifts[k], fwd.lifts[j]);
    }
    // The first point of travel is the deck's high end now.
    expect(rev.lifts.first, greaterThan(rev.lifts.last));
    expect(rev.bridges, [lengthM - 30, lengthM - 10]);
    expect(rev.startHalfWidthM, 5);
    expect(rev.endHalfWidthM, 3);
    expect(fwd.bridges, [10, 30]);
  });

  test('junction overrides reach the frame, stop legs 12 m out on each', () {
    final city = colony(spline());
    city.junctionOverrides['0,0'] = const JunctionOverride(
        at: Vec2(0, 0), lights: true, stopHeadings: [0, math.pi / 2]);
    city.junctionOverrides['40,120'] =
        const JunctionOverride(at: Vec2(40, 120), lights: false);
    city.junctionOverrides['-20,260'] =
        const JunctionOverride(at: Vec2(-20, 260), stopHeadings: []);
    final snap = capture(city);
    expect(snap.junctions, hasLength(3));

    final j = snap.junctions[0];
    expect(j.colonyId, 'roads');
    expect(j.body, 'earth');
    expect(j.lights, 1);
    expect(j.stopsSet, isTrue);
    expect(j.stopPoints, hasLength(6));
    // The ground under the junction, and each stop 12 m along its heading
    // — north, then east — at that same ground radius.
    final atBF = Vector3(j.px, j.py, j.pz);
    final r = atBF.length;
    expect(r, closeTo(earthRadius, earthRadius * 0.001));
    for (final (k, local) in [(0, const Vec2(0, 12)), (1, const Vec2(12, 0))]) {
      final want = city.localToBodyFixed(local, bodyRadiusM: r);
      expect(j.stopPoints[3 * k], closeTo(want.x, 1e-6));
      expect(j.stopPoints[3 * k + 1], closeTo(want.y, 1e-6));
      expect(j.stopPoints[3 * k + 2], closeTo(want.z, 1e-6));
    }

    expect(snap.junctions[1].lights, 0);
    expect(snap.junctions[1].stopsSet, isFalse);
    expect(snap.junctions[1].stopPoints, isEmpty);
    // Every stop taken off: set, and empty — not the default legs.
    expect(snap.junctions[2].lights, -1);
    expect(snap.junctions[2].stopsSet, isTrue);
    expect(snap.junctions[2].stopPoints, isEmpty);
  });

  test('each colony\'s roads revision reaches the frame', () {
    final city = colony(spline());
    city.roadsRevision = 7;
    expect(capture(city).roadsRevision, {'roads': 7});
  });

  test('the new fields survive the wire', () {
    final city = colony(spline(
        deck: const RoadDeck(startM: 50, endM: 60),
        reversed: true,
        decoration: RoadDecoration.grass));
    city.roadsRevision = 4;
    city.junctionOverrides['0,0'] = const JunctionOverride(
        at: Vec2(0, 0), lights: false, stopHeadings: [math.pi]);
    city.junctionOverrides['1,1'] =
        const JunctionOverride(at: Vec2(1, 1), stopHeadings: []);
    final snap = capture(city);
    final back = WorldSnapshot.fromJson(
        jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>);

    final a = snap.roads.single, b = back.roads.single;
    expect(b.id, a.id);
    expect(b.decoration, a.decoration);
    expect(b.lifts, a.lifts);
    expect(b.points, a.points);
    expect(back.roadsRevision, {'roads': 4});
    expect(back.junctions, hasLength(2));
    for (var i = 0; i < 2; i++) {
      final x = snap.junctions[i], y = back.junctions[i];
      expect([y.colonyId, y.body], [x.colonyId, x.body]);
      expect([y.px, y.py, y.pz], [x.px, x.py, x.pz]);
      expect(y.lights, x.lights);
      expect(y.stopsSet, x.stopsSet);
      expect(y.stopPoints, x.stopPoints);
    }
  });

  test('a frame from before the road tool reads as having none of it', () {
    final old = WorldSnapshot.fromJson({
      'tick': 3,
      'roads': [
        {'colony': 'c', 'body': 'moon', 'pts': [1, 2, 3, 4, 5, 6], 'hw': 4},
      ],
    });
    expect(old.roadsRevision, isEmpty);
    expect(old.junctions, isEmpty);
    final r = old.roads.single;
    expect(r.id, isNull);
    expect(r.decoration, 0);
    expect(r.lifts, isEmpty);

    final bare = JunctionSnapshot.fromJson({'p': [1, 2, 3]});
    expect([bare.px, bare.py, bare.pz], [1, 2, 3]);
    expect(bare.lights, -1);
    expect(bare.stopsSet, isFalse);
    // Malformed entries are skipped, not thrown on.
    final odd = WorldSnapshot.fromJson({
      'tick': 0,
      'roadsRev': {'c': 2, 'x': 'nope'},
      'junctions': ['nope', {'colony': 'c', 'body': 'moon', 'p': [0, 0, 1]}],
    });
    expect(odd.roadsRevision, {'c': 2});
    expect(odd.junctions, hasLength(1));
  });

  test('a frame advanced in time keeps its revision and overrides', () {
    final city = colony(spline());
    city.roadsRevision = 9;
    city.junctionOverrides['0,0'] =
        const JunctionOverride(at: Vec2(0, 0), lights: true);
    final snap = capture(city);
    final later = snap.copyWithEpoch(snap.epoch + 60);
    expect(identical(later.roadsRevision, snap.roadsRevision), isTrue);
    expect(identical(later.junctions, snap.junctions), isTrue);
  });
}
