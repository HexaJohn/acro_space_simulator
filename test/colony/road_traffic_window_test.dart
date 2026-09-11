// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The traffic model's window, and what starts a pass. A big city's origins
/// are routed a share at a time and the shares' loads summed — never a
/// sample scaled up — so it reads what routing every origin would; a road
/// edit carries the loads across; houses going up are seen without waiting
/// for the colony day; the grid's buildings count; the nearest station
/// behind a lot is the one that reaches it; land value leaves the tax take
/// alone where nothing is built; a light switched on mid-pass re-plans the
/// junction without a rebuild.
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/road_noise.dart';
import 'package:acro_space_simulator/domain/colony/city/road_traffic_model.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

CitySim colony(String id) => CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: id,
    );

CityBuildingSpec utilOfType(String type) =>
    kUtilCatalog.firstWhere((s) => s.type == type);

final homes = kZoneSpecs['residential']![Density.medium]!;
final shops = kZoneSpecs['commercial']![Density.low]!;
final works = kZoneSpecs['industrial']![Density.low]!;

/// The auto lot on [roadId] (an east-west road along n = 0) whose centroid
/// is nearest [p], on the side of the road [north] says. Lots are cut from
/// 12 m in, 24 m wide, so their frontages centre on 24, 48, 72 ... metres
/// along the road.
Parcel lotOn(CityLayout layout, String roadId, Vec2 p, {required bool north}) {
  final lots = layout.autoParcels
      .where((l) => l.roadId == roadId && (l.centroid.n > 0) == north)
      .toList()
    ..sort((a, b) =>
        a.centroid.distanceTo(p).compareTo(b.centroid.distanceTo(p)));
  return lots.first;
}

Iterable<Parcel> lotsOf(CityLayout layout, String roadId) =>
    layout.autoParcels.where((l) => l.roadId == roadId);

/// A model over [c] run to the end of one pass.
CityRoadTraffic settled(CitySim c) {
  final t = CityRoadTraffic(c,
      tuning: const TrafficTuning(workPerStep: 1 << 30));
  t.advance(1);
  expect(t.hasRun, isTrue);
  return t;
}

/// Tick [t] until [done], at most [limit] ticks of [dt].
void runUntil(CityRoadTraffic t, bool Function() done,
    {int limit = 10000, double dt = 1}) {
  for (var i = 0; i < limit && !done(); i++) {
    t.advance(dt);
  }
  expect(done(), isTrue);
}

/// A grid of [n] by [n] streets 100 m apart, running 30 m past the last
/// crossing, every lot built: mostly homes, then shops and works, and a
/// police station every eleventh lot.
CitySim builtGrid(String id, {int n = 6}) {
  final c = colony(id);
  final half = (n - 1) * 100 / 2;
  for (var i = 0; i < n; i++) {
    final x = -half + i * 100;
    c.layout.commitRoad(
        controls: [Vec2(x, -half - 30), Vec2(x, half + 30)],
        regenerateLots: false);
    c.layout.commitRoad(
        controls: [Vec2(-half - 30, x), Vec2(half + 30, x)],
        regenerateLots: false);
  }
  c.layout.regenerate();
  final police = utilOfType('police');
  final lots = c.layout.autoParcels;
  for (var i = 0; i < lots.length; i++) {
    final k = i % 11;
    c.parcelBuildings[lots[i].id] = k == 0
        ? police
        : k < 7
            ? homes
            : k < 9
                ? shops
                : works;
  }
  return c;
}

/// Every road's volume, the peak and the average, the same in [a] as in
/// [whole].
void sameLoads(CityRoadTraffic a, CityRoadTraffic whole, CitySim c) {
  expect(a.peakCongestion, closeTo(whole.peakCongestion, 1e-9));
  expect(a.model.averageCongestion,
      closeTo(whole.model.averageCongestion, 1e-9));
  for (final road in c.layout.roads) {
    final w = whole.volumeOf(road.id);
    expect(a.volumeOf(road.id), closeTo(w, 1e-9 * (1 + w)), reason: road.id);
  }
}

void main() {
  group('a window of shares', () {
    test('publishes what routing every origin in one pass would', () {
      final c = builtGrid('window');
      final whole = CityRoadTraffic(c,
          tuning: const TrafficTuning(workPerStep: 1 << 30));
      whole.advance(1);
      expect(whole.hasRun, isTrue);
      expect(whole.model.shares, 1);
      expect(whole.peakCongestion, greaterThan(0));

      final part = CityRoadTraffic(c,
          tuning: const TrafficTuning(
              workPerStep: 1 << 30, maxOriginsPerPass: 8, cadenceSec: 0));
      part.advance(1);
      final shares = part.model.shares;
      expect(shares, greaterThan(4), reason: 'the city is split');
      expect(part.hasRun, isFalse,
          reason: 'a window missing a share would be missing its traffic');
      runUntil(part, () => part.hasRun);
      expect(part.model.passes, shares);
      // Not a sample scaled up: the origins' own streets read their own
      // load, and the worst of them the colony's real congestion.
      sameLoads(part, whole, c);

      // And it stays the whole city's as the shares are routed again, one
      // a pass.
      for (var i = 0; i < 2 * shares; i++) {
        part.advance(1);
        sameLoads(part, whole, c);
      }
    });

    test('a road edit carries the loads across and publishes at once', () {
      final c = builtGrid('carry');
      final part = CityRoadTraffic(c,
          tuning: const TrafficTuning(
              workPerStep: 1 << 30, maxOriginsPerPass: 8, cadenceSec: 1e9));
      runUntil(part, () => part.hasRun && !part.model.needsRefresh);
      final passes = part.model.passes;

      // A lane out in the fields: nothing is built on it, and no route
      // changes — a new graph, all the same.
      c.commitRoad(const [Vec2(3000, 3000), Vec2(3300, 3000)], RoadClass.street);
      part.advance(1);
      expect(part.model.passes, passes + 1);
      expect(part.model.needsRefresh, isTrue,
          reason: 'the other shares are carried, not yet re-routed');

      // One pass after the edit, the whole city — not one share scaled up.
      final whole = CityRoadTraffic(c,
          tuning: const TrafficTuning(workPerStep: 1 << 30));
      whole.advance(1);
      sameLoads(part, whole, c);

      // The rest of the window is re-routed straight away, a share a pass.
      runUntil(part, () => !part.model.needsRefresh && !part.model.passing);
      sameLoads(part, whole, c);
    });
  });

  group('what starts a pass', () {
    test('houses going up are seen without waiting for the colony day', () {
      final c = colony('growth');
      final main =
          c.commitRoad(const [Vec2(0, -150), Vec2(0, 150)], RoadClass.street)!;
      final lots = lotsOf(c.layout, main).toList();
      for (final lot in lots) {
        c.layout.setUse(lot.id, ParcelUse.residential);
        // Zoned and growing — so counted among the growing lots — but
        // still bare ground.
        c.grownParcels[lot.id] = 0.1;
      }
      // A slow-turning world: a colony day is twenty minutes of play.
      final t = CityRoadTraffic(c,
          tuning: const TrafficTuning(workPerStep: 1 << 30, cadenceSec: 1200));
      t.advance(0.1);
      expect(t.hasRun, isTrue);
      expect(t.volumeOf(main), 0, reason: 'nothing built yet');
      var passes = t.model.passes;

      // The houses go up; not a lot is added or taken away.
      for (final lot in lots) {
        c.grownParcels[lot.id] = 1.0;
      }
      t.advance(0.1);
      expect(t.model.passes, passes, reason: 'too soon after the last pass');
      t.advance(2);
      expect(t.model.passes, passes + 1);
      final low = t.volumeOf(main);
      expect(low, greaterThan(0));

      // They grow a storey.
      passes = t.model.passes;
      for (final lot in lots) {
        c.grownParcels[lot.id] = 2.5;
      }
      t.advance(2.1);
      expect(t.model.passes, passes + 1);
      expect(t.volumeOf(main), greaterThan(low));

      // Nothing changing, nothing runs.
      passes = t.model.passes;
      t.advance(10);
      expect(t.model.passes, passes);
    });
  });

  group('service reach', () {
    test('the nearest station behind a lot on its street is the one that '
        'reaches it', () {
      final c = colony('two stations');
      final s =
          c.commitRoad(const [Vec2(0, 0), Vec2(600, 0)], RoadClass.street)!;
      c.placeOnParcel(lotOn(c.layout, s, const Vec2(48, -20), north: false).id,
          utilOfType('police'));
      c.placeOnParcel(
          lotOn(c.layout, s, const Vec2(504, -20), north: false).id,
          utilOfType('clinic'));
      final house = lotOn(c.layout, s, const Vec2(552, -20), north: false);
      final t = settled(c);
      // Straight on from the clinic; the police station further back is
      // not the nearest.
      expect(t.model.serviceDistanceTo(house.id), closeTo(48, 2));
    });

    test('a one-way street longer than the reach still reaches the lot just '
        'past a station', () {
      final c = colony('long one-way');
      final s = c.commitRoad(
          const [Vec2(0, 0), Vec2(4200, 0)], RoadClass.streetOneWay)!;
      c.placeOnParcel(lotOn(c.layout, s, const Vec2(48, -20), north: false).id,
          utilOfType('police'));
      c.placeOnParcel(
          lotOn(c.layout, s, const Vec2(4008, -20), north: false).id,
          utilOfType('clinic'));
      final house = lotOn(c.layout, s, const Vec2(4104, -20), north: false);
      final t = settled(c);
      expect(t.serviceReach(house.id), isTrue);
      expect(t.model.serviceDistanceTo(house.id), closeTo(96, 2));
    });
  });

  group('land value and the tax take', () {
    test('no built lot, no change to the take — polluted or not', () {
      final c = colony('bare');
      c.pollution = 30;
      final t = settled(c);
      expect(t.model.builtLots, 0);
      expect(t.taxLandValueFactor, 1.0);
      expect(t.averageLandValue, lessThan(RoadNoise.baseLandValue),
          reason: 'the air is what it is');

      // Homes in that air: the air costs them value, and the take.
      final main =
          c.commitRoad(const [Vec2(0, -150), Vec2(0, 150)], RoadClass.street)!;
      for (final lot in lotsOf(c.layout, main)) {
        c.placeOnParcel(lot.id, homes);
      }
      t.advance(1);
      expect(t.model.builtLots, greaterThan(0));
      expect(t.taxLandValueFactor, lessThan(1.0));
    });
  });

  group('grid buildings', () {
    test('a police station placed on the grid answers calls along the '
        'streets', () {
      final c = colony('grid police');
      final main =
          c.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street)!;
      final house = lotOn(c.layout, main, const Vec2(96, 20), north: true);
      c.placeOnParcel(house.id, homes);
      expect(settled(c).serviceReach(house.id), isFalse,
          reason: 'no station at all');

      // The 2D builder's police station: the cell whose footprint sits
      // nearest a spot sixty metres off the street.
      final police = utilOfType('police');
      var anchor = -1;
      var best = double.infinity;
      for (var k = 0; k < c.grid * c.grid; k++) {
        final d = c
            .parcelForCell(k, police)
            .centroid
            .distanceTo(const Vec2(-60, -60));
        if (d < best) {
          best = d;
          anchor = k;
        }
      }
      c.utils[anchor] = police;
      final t = settled(c);
      expect(t.serviceReach(house.id), isTrue);
      expect(t.model.serviceDistanceTo(house.id), lessThan(400));
    });
  });

  group('junction overrides', () {
    /// Homes on O, a mall on D, and two ways between: A, straight through
    /// a crossing with C; B, round the crossing, about a hundred metres
    /// (nine seconds) longer.
    ({CitySim c, String a, String b}) twoRoutes() {
      final c = colony('routes');
      final o =
          c.commitRoad(const [Vec2(-400, 0), Vec2(-200, 0)], RoadClass.street)!;
      final a =
          c.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street)!;
      final b = c.commitRoad(const [
        Vec2(-200, 0),
        Vec2(-100, 112),
        Vec2(100, 112),
        Vec2(200, 0),
      ], RoadClass.street)!;
      final d =
          c.commitRoad(const [Vec2(200, 0), Vec2(400, 0)], RoadClass.street)!;
      c.commitRoad(const [Vec2(0, -100), Vec2(0, 60)], RoadClass.street);
      for (final lot in lotsOf(c.layout, o)) {
        c.placeOnParcel(lot.id, homes);
      }
      for (final lot in lotsOf(c.layout, d)) {
        c.placeOnParcel(lot.id, shops);
      }
      return (c: c, a: a, b: b);
    }

    test('a light switched on mid-pass re-plans the junction without '
        'dropping the pass', () {
      final r = twoRoutes();
      final t = CityRoadTraffic(r.c,
          tuning: const TrafficTuning(workPerStep: 40));
      t.advance(0.1);
      expect(t.model.passing, isTrue);
      final before = t.graph;
      expect(before.nodeNear(const Vec2(0, 0))!.control, JunctionControl.stop);

      // The Junctions view switches the crossing's lights on.
      r.c.junctionOverrides[JunctionOverride.keyFor(const Vec2(0, 0))] =
          const JunctionOverride(at: Vec2(0, 0), lights: true);
      t.advance(0.1);
      final after = t.graph;
      expect(identical(after, before), isFalse);
      expect(after.sharesStructureWith(before), isTrue,
          reason: 're-planned, not rebuilt');
      expect(after.nodeNear(const Vec2(0, 0))!.control,
          JunctionControl.signals);
      expect(t.model.passing, isTrue, reason: 'the pass in flight carries on');
      expect(t.model.passes, 0);

      // It finishes, and a pass under the light follows: what a model built
      // under the light from the start says.
      runUntil(t,
          () => t.hasRun && !t.model.needsRefresh && !t.model.passing,
          dt: 0.1, limit: 100000);
      final fresh = settled(r.c);
      expect(t.volumeOf(r.b), greaterThan(100),
          reason: 'the homes go round the light');
      expect(t.volumeOf(r.b), closeTo(fresh.volumeOf(r.b), 1e-6));
      expect(t.volumeOf('${r.a}x0'), closeTo(fresh.volumeOf('${r.a}x0'), 1e-6));
    });
  });
}
