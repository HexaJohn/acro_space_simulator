// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// An expressway meets nothing at grade: where a road crosses one, the
/// expressway is carried over on a bridge and neither is cut. Bridges and
/// tapers are attributes of the road, survive its splits, and reach the
/// wire.
library;

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ew = [Vec2(-2000, 0), Vec2(2000, 0)];
  const ns = [Vec2(0, -1500), Vec2(0, 1500)];

  test('a street crossing an expressway is bridged, not cut, either way round',
      () {
    // The expressway first.
    final a = CityLayout();
    a.commitRoad(
        controls: ew, roadClass: RoadClass.expressway6, regenerateLots: false);
    final r = a.commitRoad(controls: ns, regenerateLots: false);
    expect(a.roads.length, 2, reason: 'neither road is cut');
    expect(r.crossings, hasLength(1));
    expect(r.crossings.single.bridged, isTrue);
    expect(r.crossings.single.otherId, 'r0');
    final x = a.roadById('r0')!;
    expect(x.bridges, hasLength(1));
    expect(x.bridges.single.$1, closeTo(2000 - CityLayout.bridgeHalfM, 1e-6));
    expect(x.bridges.single.$2, closeTo(2000 + CityLayout.bridgeHalfM, 1e-6));
    expect(x.bridgedAt(2000), isTrue);
    expect(a.roadById('r1')!.bridges, isEmpty);

    // The street first: the expressway laid over it carries the bridge.
    final b = CityLayout();
    b.commitRoad(controls: ns, regenerateLots: false);
    final rb = b.commitRoad(
        controls: ew, roadClass: RoadClass.expressway6, regenerateLots: false);
    expect(b.roads.length, 2);
    expect(rb.crossings.single.bridged, isTrue);
    expect(b.roadById('r1')!.bridges, hasLength(1));
    expect(b.roadById('r0')!.bridges, isEmpty);
  });

  test('two expressways: the one already laid goes over', () {
    final l = CityLayout();
    l.commitRoad(
        controls: ew, roadClass: RoadClass.expressway6, regenerateLots: false);
    l.commitRoad(
        controls: ns, roadClass: RoadClass.expressway4, regenerateLots: false);
    expect(l.roads.length, 2);
    expect(l.roadById('r0')!.bridges, hasLength(1));
    expect(l.roadById('r1')!.bridges, isEmpty);
  });

  test('a ramp meets an expressway at grade: a merge, so the road is cut', () {
    final l = CityLayout();
    l.commitRoad(
        controls: ew, roadClass: RoadClass.expressway6, regenerateLots: false);
    // A ramp crossing the centreline (a test shape; a real one joins the
    // edge) is a junction, not a bridge.
    final r = l.commitRoad(
        controls: const [Vec2(100, -200), Vec2(100, 200)],
        roadClass: RoadClass.ramp,
        regenerateLots: false);
    expect(r.crossings.single.bridged, isFalse);
    expect(l.roads.length, 4);
    expect(l.roads.every((x) => x.bridges.isEmpty), isTrue);
  });

  test('near an expressway\'s end nothing is bridged, and nothing is cut', () {
    final l = CityLayout();
    l.commitRoad(
        controls: ew, roadClass: RoadClass.expressway6, regenerateLots: false);
    l.commitRoad(
        controls: const [Vec2(-1900, -300), Vec2(-1900, 300)],
        regenerateLots: false);
    expect(l.roads.length, 2);
    expect(l.roadById('r0')!.bridges, isEmpty);
  });

  test('a road under an existing bridge is not cut by it', () {
    final l = CityLayout();
    l.commitRoad(
        controls: ew, roadClass: RoadClass.expressway6, regenerateLots: false);
    l.commitRoad(controls: ns, regenerateLots: false);
    // A second street thirty metres over, under the same deck.
    final r = l.commitRoad(
        controls: const [Vec2(30, -400), Vec2(30, 400)], regenerateLots: false);
    expect(r.crossings.single.bridged, isTrue);
    expect(l.roads.length, 3);
    // The bridge grew no second range: the crossing was already under it.
    expect(l.roadById('r0')!.bridges, hasLength(1));
  });

  test('bridges shift with a split and are never clipped to a piece', () {
    final l = CityLayout();
    l.commitRoad(
        controls: ew,
        roadClass: RoadClass.expressway6,
        bridges: const [(1900, 2300)],
        startHalfWidthM: 8,
        endHalfWidthM: 12.2,
        regenerateLots: false);
    // A crossing under the deck is bridged, never a cut — so the cut that
    // exercises the shift is a merge, made outright at s = 2100.
    l.commitRoad(
        controls: const [Vec2(100, -200), Vec2(100, 200)],
        roadClass: RoadClass.ramp,
        regenerateLots: false);
    expect(l.roads.length, 2, reason: 'the ramp passed under the deck');
    expect(l.splitRoadAt('r0', 2100), ['r0x0', 'r0x1']);
    final pieces = l.roads.where((r) => r.id.startsWith('r0')).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    expect(pieces, hasLength(2));
    final (first, second) = (pieces[0], pieces[1]);
    // The first piece keeps the range as it was; the second sees it
    // shifted back by its own start — beginning before it does.
    expect(first.bridges.single, (1900.0, 2300.0));
    expect(second.bridges.single.$1, closeTo(-200, 1e-6));
    expect(second.bridges.single.$2, closeTo(200, 1e-6));
    // The tapers stay with the ends they belong to.
    expect(first.startHalfWidthM, 8);
    expect(first.endHalfWidthM, isNull);
    expect(second.startHalfWidthM, isNull);
    expect(second.endHalfWidthM, 12.2);
  });

  test('splitRoadAt cuts a road where nothing crosses it', () {
    final l = CityLayout();
    l.commitRoad(
        controls: ew, roadClass: RoadClass.expressway6, regenerateLots: false);
    final ids = l.splitRoadAt('r0', 1500)!;
    expect(ids, ['r0x0', 'r0x1']);
    expect(l.roads.length, 2);
    expect(l.roadIndex.byId('r0x0')!.lengthM, closeTo(1500, 1e-6));
    expect(l.roadIndex.byId('r0x1')!.lengthM, closeTo(2500, 1e-6));
    expect(l.splitRoadAt('r0x0', 3), isNull);
    expect(l.splitRoadAt('nope', 100), isNull);
  });

  test('an end told not to snap stays where it was drawn', () {
    final l = CityLayout();
    l.commitRoad(controls: ew, regenerateLots: false);
    l.commitRoad(
        controls: const [Vec2(500, 10), Vec2(500, 300)],
        snapStart: false,
        regenerateLots: false);
    expect(l.roads.length, 2, reason: 'no T: the end never touched the road');
    expect(l.roadById('r1')!.controls.first.n, 10);
    l.commitRoad(
        controls: const [Vec2(900, 10), Vec2(900, 300)], regenerateLots: false);
    expect(l.roads.length, 4, reason: 'snapped: a T that cuts the road');
  });

  test('updateRoad changes attributes and keeps the geometry indexed', () {
    final l = CityLayout();
    l.commitRoad(
        controls: ew, roadClass: RoadClass.expressway6, regenerateLots: false);
    final road = l.roadById('r0')!;
    expect(l.updateRoad(road.copyWith(soundWalls: true)), isTrue);
    expect(l.roadById('r0')!.soundWalls, isTrue);
    expect(l.roadIndex.byId('r0')!.road.soundWalls, isTrue);
    expect(l.nearestRoadPoint(const Vec2(700, 3), withinM: 5), isNotNull);
    expect(l.updateRoad(road.copyWith(id: 'ghost')), isFalse);
  });

  test('bridges and tapers survive the colony save', () {
    final system = RealSolarSystem.build();
    final bodies = system.all.where((b) => !b.isStar).toList();
    final sim = CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20, latitude: 0, longitude: 0),
        bodies: bodies,
        id: 'c',
        name: 'c');
    sim.stock['ore'] = 1e9;
    sim.commitRoad(ew, RoadClass.expressway6,
        bridges: const [(300, 700)], startHalfWidthM: 8, endHalfWidthM: 12.2);
    final back = CitySim.fromJson(sim.toJson(), bodies: bodies);
    final r = back.layout.roadById('r0')!;
    expect(r.bridges, [(300.0, 700.0)]);
    expect(r.startHalfWidthM, 8);
    expect(r.endHalfWidthM, 12.2);
  });
}
