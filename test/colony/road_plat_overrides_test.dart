// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A road can say how it is platted: what frontage and depth its lots get,
/// whether it plats lots at all, and whether it is a collector. The
/// layout's settings are the colony's default; a suburb's street is not
/// a downtown assemblage and a county highway fronts nothing.
library;

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const a = Vec2(-300, 0), b = Vec2(300, 0);

  test('a road with its own frontage cuts narrower lots than the default',
      () {
    final layout = CityLayout(
        settings: const ParcelSettings(frontageM: 30, cornerClearM: 0));
    layout.commitRoad(controls: const [a, b], regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(-300, 200), Vec2(300, 200)],
        lotFrontageM: 15,
        lotDepthM: 20,
        regenerateLots: false);
    layout.regenerate();
    final wide = layout.autoParcels.where((p) => p.roadId == 'r0').toList();
    final narrow = layout.autoParcels.where((p) => p.roadId == 'r1').toList();
    expect(wide, isNotEmpty);
    expect(narrow.length, greaterThan(wide.length * 1.6));
    expect(narrow.first.frontageWidth, closeTo(15, 1));
    expect(wide.first.frontageWidth, closeTo(30, 1));
    // Depth follows too.
    final ext = narrow.first.buildableExtent;
    expect(ext.depth, lessThanOrEqualTo(20.5));
  });

  test('a road told not to plat lots fronts nothing', () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [a, b], roadClass: RoadClass.avenue, frontsLots: false);
    expect(layout.autoParcels, isEmpty);
    // The same road by class alone would have.
    final control = CityLayout();
    control.commitRoad(controls: const [a, b], roadClass: RoadClass.avenue);
    expect(control.autoParcels, isNotEmpty);
  });

  test('a split carries the overrides and the collector flag to its pieces',
      () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [a, b],
        lotFrontageM: 18,
        lotDepthM: 30,
        collector: true,
        regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(0, -200), Vec2(0, 200)], regenerateLots: false);
    final pieces = layout.roads.where((r) => r.id.startsWith('r0')).toList();
    expect(pieces, hasLength(2));
    for (final p in pieces) {
      expect(p.lotFrontageM, 18);
      expect(p.lotDepthM, 30);
      expect(p.collector, isTrue);
    }
    for (final p in layout.roads.where((r) => r.id.startsWith('r1'))) {
      expect(p.collector, isFalse);
      expect(p.lotFrontageM, isNull);
    }
  });

  test('a straight road is held as one segment and still cuts and snaps', () {
    final layout = CityLayout();
    layout.commitRoad(controls: const [a, b], regenerateLots: false);
    expect(layout.roadIndex.byId('r0')!.sampleCount, 2);
    // Crossing and end-snapping still work off the single segment.
    layout.commitRoad(
        controls: const [Vec2(50, -100), Vec2(50, 100)], regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(-100, 12), Vec2(-100, 150)], regenerateLots: false);
    // r0 cut by the crossing and again by the T: 3 pieces; r1: 2; r2: 1.
    expect(layout.roads.length, 3 + 2 + 1);
    expect(layout.nearestRoadPoint(const Vec2(120, 3), withinM: 5)!.point.n,
        closeTo(0, 1e-9));
  });

  test('the overrides survive a save and a load', () {
    final system = RealSolarSystem.build();
    final bodies = system.all.where((b) => !b.isStar).toList();
    final sim = CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20, latitude: 0, longitude: 0),
        bodies: bodies,
        id: 'c',
        name: 'c');
    sim.stock['ore'] = 1e9;
    sim.commitRoad(const [a, b], RoadClass.street,
        lotFrontageM: 21, lotDepthM: 33, frontsLots: true, collector: true);
    sim.commitRoad(const [Vec2(-300, 400), Vec2(300, 400)], RoadClass.avenue,
        frontsLots: false);
    final back = CitySim.fromJson(sim.toJson(), bodies: bodies);
    final r0 = back.layout.roads.firstWhere((r) => r.id == 'r0');
    final r1 = back.layout.roads.firstWhere((r) => r.id == 'r1');
    expect(r0.lotFrontageM, 21);
    expect(r0.lotDepthM, 33);
    expect(r0.collector, isTrue);
    expect(r0.platsLots, isTrue);
    expect(r1.platsLots, isFalse);
    expect(r1.frontsLots, isFalse);
    expect(back.layout.autoParcels.where((p) => p.roadId == 'r1'), isEmpty);
  });
}
