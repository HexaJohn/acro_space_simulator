// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Routed traffic: one-way streets and medians change who can reach whom,
/// junction delays change which way traffic goes, the routes view shows
/// the trips on a road, and noise follows the traffic and the dressing.
library;

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
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

CityBuildingSpec util(String label) =>
    kUtilCatalog.firstWhere((s) => s.label == label);

final homes = kZoneSpecs['residential']![Density.low]!;
final mall = kZoneSpecs['commercial']![Density.medium]!;

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

/// The lots of [roadId], each side.
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

void main() {
  group('service reach', () {
    /// A 400 x 100 m block; the bottom street of [bottom]'s class, drawn
    /// east. A police station on it at 288 m, a house at 96 m, both on the
    /// south kerb. Route metres from one to the other.
    double loop(RoadClass bottom, {double w = 400, double h = 100}) {
      final c = colony('loop');
      final s1 = c.commitRoad([const Vec2(0, 0), Vec2(w, 0)], bottom)!;
      c.commitRoad([Vec2(0, h), Vec2(w, h)], RoadClass.street);
      c.commitRoad([const Vec2(0, 0), Vec2(0, h)], RoadClass.street);
      c.commitRoad([Vec2(w, 0), Vec2(w, h)], RoadClass.street);
      final station = lotOn(c.layout, s1, Vec2(w - 112, -20), north: false);
      final house = lotOn(c.layout, s1, const Vec2(96, -20), north: false);
      expect(c.placeOnParcel(station.id, util('Police Station')), isTrue);
      final t = settled(c);
      return t.model.serviceDistanceTo(house.id) ?? double.infinity;
    }

    test('a one-way street sends the police the long way round', () {
      // Two-way: straight back along the street.
      expect(loop(RoadClass.street), closeTo(192, 2));
      // One-way east: on to the corner, round the block, back in at the
      // start — 112 + 100 + 400 + 100 + 96.
      expect(loop(RoadClass.streetOneWay), closeTo(808, 2));
    });

    test('past four kilometres of route a lot is out of reach', () {
      final c = colony('bigloop');
      final s1 = c.commitRoad(
          const [Vec2(0, 0), Vec2(3000, 0)], RoadClass.streetOneWay)!;
      c.commitRoad(const [Vec2(0, 1000), Vec2(3000, 1000)], RoadClass.street);
      c.commitRoad(const [Vec2(0, 0), Vec2(0, 1000)], RoadClass.street);
      c.commitRoad(const [Vec2(3000, 0), Vec2(3000, 1000)], RoadClass.street);
      final station =
          lotOn(c.layout, s1, const Vec2(2904, -20), north: false);
      final behind = lotOn(c.layout, s1, const Vec2(96, -20), north: false);
      final ahead = lotOn(c.layout, s1, const Vec2(2976, -20), north: false);
      c.placeOnParcel(station.id, util('Police Station'));
      final t = settled(c);
      // 2,808 m back the way the street runs the wrong way; 5.2 km round.
      expect(t.serviceReach(behind.id), isFalse);
      expect(t.serviceReach(ahead.id), isTrue);
      expect(t.model.serviceDistanceTo(ahead.id), closeTo(72, 2));
    });

    test("a four-lane road's median sends it round to the far kerb", () {
      double distance(RoadClass cls, {required bool targetNorth}) {
        final c = colony('median');
        final id = c.commitRoad(const [Vec2(0, 0), Vec2(400, 0)], cls)!;
        final station = lotOn(c.layout, id, const Vec2(288, 30), north: true);
        final target = lotOn(c.layout, id, Vec2(96, targetNorth ? 30 : -30),
            north: targetNorth);
        c.placeOnParcel(station.id, util('Police Station'));
        return settled(c).model.serviceDistanceTo(target.id)!;
      }

      // The north kerb is left of eastbound traffic: on a four-lane road
      // its lots are reached, and left, westbound only. Same kerb: straight
      // there. Far kerb: west to the end, turn, and back — 288 + 96.
      expect(distance(RoadClass.avenue, targetNorth: true), closeTo(192, 2));
      expect(distance(RoadClass.avenue, targetNorth: false), closeTo(384, 2));
      // A two-lane street has no median to go round.
      expect(distance(RoadClass.street, targetNorth: false), closeTo(192, 2));
    });

    test('reversing a one-way road flips which lots it can reach', () {
      ({bool service, bool goods, bool home}) reach({required bool reversed}) {
        final c = colony('rev');
        final s = c.commitRoad(
            const [Vec2(-100, 0), Vec2(100, 0)], RoadClass.street)!;
        final o = c.commitRoad(
            const [Vec2(100, 0), Vec2(400, 0)], RoadClass.streetOneWay)!;
        if (reversed) {
          c.layout.updateRoad(c.layout.roadById(o)!.copyWith(reversed: true));
        }
        final station = lotOn(c.layout, s, const Vec2(-52, 20), north: true);
        final shop = lotOn(c.layout, o, const Vec2(220, 20), north: true);
        final home = lotOn(c.layout, s, const Vec2(28, -20), north: false);
        c.placeOnParcel(station.id, util('Police Station'));
        c.placeOnParcel(shop.id, mall);
        final t = settled(c);
        return (
          service: t.serviceReach(shop.id),
          goods: t.deliveryReach(shop.id),
          home: t.serviceReach(home.id) && t.deliveryReach(home.id),
        );
      }

      final east = reach(reversed: false);
      expect(east.service, isTrue);
      expect(east.goods, isTrue, reason: 'in off-world through the landing site');
      expect(east.home, isTrue);
      // Reversed, the one-way road runs INTO the junction from a dead end
      // nothing reaches: its lots are cut off.
      final west = reach(reversed: true);
      expect(west.service, isFalse);
      expect(west.goods, isFalse);
      expect(west.home, isTrue);
    });

    test("a clinic's ambulance is no fire cover", () {
      // A one-way street east, and a house on it the police station down
      // the street cannot reach: nothing leads back. In one colony a
      // clinic stands up the street from the house.
      ({bool service, bool fire, double burn}) house({required bool clinic}) {
        final c = colony('fire');
        final s = c.commitRoad(
            const [Vec2(0, 0), Vec2(600, 0)], RoadClass.streetOneWay)!;
        final station = lotOn(c.layout, s, const Vec2(504, -20), north: false);
        final home = lotOn(c.layout, s, const Vec2(144, -20), north: false);
        expect(c.placeOnParcel(station.id, util('Police Station')), isTrue);
        expect(c.placeOnParcel(home.id, homes), isTrue);
        if (clinic) {
          final at = lotOn(c.layout, s, const Vec2(48, -20), north: false);
          expect(c.placeOnParcel(at.id, util('Clinic')), isTrue);
        }
        c.roadTraffic.advance(1);
        expect(c.trafficReadout.hasRun, isTrue);
        // Cover enough to put the fire out, if an engine could get there.
        c.population = 100;
        c.services['safety'] = 100;
        c.lotFires[home.id] = 0.5;
        c.advanceParcelFires(0.1);
        return (
          service: c.trafficReadout.serviceReach(home.id),
          fire: c.trafficReadout.fireReach(home.id),
          burn: c.lotFires[home.id] ?? 0,
        );
      }

      final alone = house(clinic: false);
      expect(alone.service, isFalse);
      expect(alone.fire, isFalse);
      expect(alone.burn, greaterThan(0.5), reason: 'out of reach, it spreads');
      final beside = house(clinic: true);
      expect(beside.service, isTrue, reason: 'the ambulance gets there');
      expect(beside.fire, isFalse, reason: 'but no engine does');
      expect(beside.burn, closeTo(alone.burn, 1e-12),
          reason: 'an ambulance puts no fire out');
    });

    test('a works on a street nothing reaches is not its own delivery', () {
      // The reversed one-way of the test above: it runs INTO the junction
      // from a dead end. A works grown on it ships goods — but only away,
      // towards the junction, never back to its own door.
      ({bool goods, double grown}) works({required bool reversed}) {
        final c = colony('selfsupply');
        c.commitRoad(const [Vec2(-100, 0), Vec2(100, 0)], RoadClass.street);
        final o = c.commitRoad(
            const [Vec2(100, 0), Vec2(400, 0)], RoadClass.streetOneWay)!;
        if (reversed) {
          c.layout.updateRoad(c.layout.roadById(o)!.copyWith(reversed: true));
        }
        final lot = lotOn(c.layout, o, const Vec2(220, 20), north: true);
        c.layout.setUse(lot.id, ParcelUse.industrial);
        c.grownParcels[lot.id] = 1.5;
        c.infiniteDemand = true;
        c.roadTraffic.advance(1);
        expect(c.trafficReadout.hasRun, isTrue);
        final goods = c.trafficReadout.deliveryReach(lot.id);
        c.advanceParcelGrowth(10);
        return (goods: goods, grown: c.grownParcels[lot.id] ?? 0);
      }

      final east = works(reversed: false);
      expect(east.goods, isTrue, reason: 'in off-world through the landing site');
      expect(east.grown, greaterThan(1.5));
      final west = works(reversed: true);
      expect(west.goods, isFalse);
      expect(west.grown, lessThan(1.5), reason: 'what stands declines');
    });
  });

  group('routing', () {
    /// Homes on O, a mall on D, and two ways between: A, straight through
    /// a crossing with C; B, round the crossing, about a hundred metres
    /// (nine seconds) longer.
    ({CitySim c, String o, String a, String b, String d}) twoRoutes() {
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
        c.placeOnParcel(lot.id, mall);
      }
      return (c: c, o: o, a: a, b: b, d: d);
    }

    test('a traffic light on the short way sends traffic the long way', () {
      final plain = twoRoutes();
      final t0 = settled(plain.c);
      final crossing = t0.graph.nodeNear(const Vec2(0, 0))!;
      expect(crossing.control, JunctionControl.stop);
      // The long way is nine seconds longer: more than the stop costs, less
      // than the light.
      final bLen = t0.graph.roadRecs[t0.graph.roadNoOf(plain.b)!].lengthM;
      expect(bLen - 400, inInclusiveRange(70, 130));
      expect(t0.volumeOf(plain.b), lessThan(1),
          reason: 'through the stop is quicker');
      expect(t0.volumeOf(plain.o), greaterThan(100));

      final lit = twoRoutes();
      lit.c.junctionOverrides[JunctionOverride.keyFor(const Vec2(0, 0))] =
          const JunctionOverride(at: Vec2(0, 0), lights: true);
      final t1 = settled(lit.c);
      expect(t1.graph.nodeNear(const Vec2(0, 0))!.control,
          JunctionControl.signals);
      expect(t1.volumeOf(lit.b), closeTo(t0.volumeOf(plain.o), 1e-6),
          reason: 'every car from the homes now goes round the light');
    });

    test('the routes through a road are the trips that use it', () {
      final r = twoRoutes();
      final t = settled(r.c);
      final onO = t.routesThrough(r.o);
      expect(onO, isNotEmpty);
      for (final route in onO) {
        expect(route.roadIds.first, r.o);
        expect(route.roadIds.last, r.d);
        // Straight along A — cut in two where C crosses it.
        expect(route.roadIds.sublist(1, route.roadIds.length - 1),
            ['${r.a}x0', '${r.a}x1']);
        expect(route.roadIds, isNot(contains(r.b)));
        expect(route.polyline.length, greaterThanOrEqualTo(3));
        expect(route.polyline.first.e, closeTo(-300, 30));
        expect(route.polyline.last.e, closeTo(300, 30));
        expect(route.weight, greaterThan(0));
      }
      expect({for (final x in onO) x.kind},
          {TripKind.commuter, TripKind.shopper});
      // The mall's deliveries come in from the landing site at the
      // crossing, not past the homes.
      expect(t.routesThrough(r.o, kinds: {TripKind.goods}), isEmpty);
      final goods = t.routesThrough(r.d, kinds: {TripKind.goods});
      expect(goods, isNotEmpty);
      expect(goods.every((x) => x.kind == TripKind.goods), isTrue);
      expect(t.routesThrough(r.b), isEmpty);
    });

    test('the same homes choke a dirt track that a street carries', () {
      double peak(RoadClass cls) {
        final c = colony('choke');
        final id = c.commitRoad(const [Vec2(0, -150), Vec2(0, 150)], cls)!;
        for (final lot in lotsOf(c.layout, id)) {
          c.layout.setUse(lot.id, ParcelUse.residential);
          c.grownParcels[lot.id] = 1.0;
        }
        return settled(c).peakCongestion;
      }

      final track = peak(RoadClass.path);
      final street = peak(RoadClass.street);
      expect(street, greaterThan(0), reason: 'they drive out to work');
      expect(track, greaterThan(street));
    });

    test('the model re-runs when the roads or the buildings change', () {
      final c = colony('adapter');
      final main =
          c.commitRoad(const [Vec2(0, -150), Vec2(0, 150)], RoadClass.street)!;
      final t = CityRoadTraffic(c,
          tuning: const TrafficTuning(workPerStep: 1 << 30));
      t.advance(0.1);
      expect(t.hasRun, isTrue);
      expect(t.peakCongestion, 0);
      final passes = t.model.passes;
      t.advance(0.1);
      expect(t.model.passes, passes, reason: 'nothing changed');
      for (final lot in lotsOf(c.layout, main)) {
        c.placeOnParcel(lot.id, homes);
      }
      t.advance(0.1);
      expect(t.model.passes, passes, reason: 'too soon after the last pass');
      t.advance(2);
      expect(t.model.passes, passes + 1);
      expect(t.peakCongestion, greaterThan(0));
      // A road: a new graph, and a pass on it straight away.
      c.commitRoad(const [Vec2(-150, 0), Vec2(150, 0)], RoadClass.street);
      t.advance(0.1);
      expect(t.model.passes, passes + 2);
      expect(t.graph.roadCount, 4);
      expect(t.graph.nodeNear(const Vec2(0, 0))!.legs, hasLength(4));
    });
  });

  group('noise and land value', () {
    /// Noise and land value at the lot at 192 m on the north kerb of a
    /// 400 m street dressed with [deco].
    (double, double) streetLot(RoadDecoration deco) {
      final layout = CityLayout();
      final id = layout
          .commitRoad(controls: const [Vec2(0, 0), Vec2(400, 0)])
          .roadId;
      if (deco != RoadDecoration.none) {
        layout.updateRoad(layout.roadById(id)!.copyWith(decoration: deco));
      }
      final lot = lotOn(layout, id, const Vec2(192, 20), north: true);
      final m = CityTrafficModel(RoadGraph.of(layout))
        ..runPass((_) => const TrafficLot.bare());
      return (m.noiseOf(lot.id), m.landValueOf(lot.id));
    }

    test('grass and trees quieten a street and raise its land value', () {
      final (plain, plainValue) = streetLot(RoadDecoration.none);
      final (grass, grassValue) = streetLot(RoadDecoration.grass);
      final (trees, treesValue) = streetLot(RoadDecoration.trees);
      expect(plain, greaterThan(0));
      expect(grass, closeTo(plain * 0.8, 1e-6));
      expect(trees, closeTo(plain * 0.6, 1e-6));
      expect(grassValue, greaterThan(plainValue));
      expect(treesValue, greaterThan(grassValue));
    });

    /// A street with lots, and 60 m north of it a highway ([walls] or
    /// not). The layout, the street's id, the highway's id.
    (CityLayout, String, String) besideHighway({bool walls = false}) {
      final layout = CityLayout();
      final st = layout
          .commitRoad(controls: const [Vec2(0, 0), Vec2(400, 0)])
          .roadId;
      final hw = layout
          .commitRoad(
              controls: const [Vec2(0, 60), Vec2(400, 60)],
              roadClass: RoadClass.motorway,
              soundWalls: walls)
          .roadId;
      return (layout, st, hw);
    }

    double noiseNextToHighway(CityLayout layout, String st) {
      final lot = lotOn(layout, st, const Vec2(192, 20), north: true);
      final m = CityTrafficModel(RoadGraph.of(layout))
        ..runPass((_) => const TrafficLot.bare());
      return m.noiseOf(lot.id);
    }

    test('sound barriers take the highway out of the noise', () {
      final (open, st, _) = besideHighway();
      final (walled, st2, _) = besideHighway(walls: true);
      final a = noiseNextToHighway(open, st);
      final b = noiseNextToHighway(walled, st2);
      expect(b, lessThan(a));
      expect(b, greaterThan(0), reason: 'the street is still there');
    });

    test('a road in a tunnel throws no noise at all', () {
      (double, double) both(CityLayout layout, String st) {
        final g = RoadGraph.of(layout);
        final lot = lotOn(layout, st, const Vec2(192, 20), north: true);
        final everything = Float64List(g.pieceCount)
          ..fillRange(0, g.pieceCount, 0.5);
        final streetOnly = Float64List(g.pieceCount);
        for (var p = 0; p < g.pieceCount; p++) {
          if (g.roads[g.pieceRoad[p]].id == st) streetOnly[p] = 0.5;
        }
        final s = RoadNoiseSampler(g);
        return (
          s.noiseAt(lot.centroid, everything),
          s.noiseAt(lot.centroid, streetOnly)
        );
      }

      final (open, st, _) = besideHighway();
      final (withHighway, withoutHighway) = both(open, st);
      expect(withHighway, greaterThan(withoutHighway));

      final (sunk, st2, hw) = besideHighway();
      final len = sunk.roadIndex.byId(hw)!.lengthM;
      sunk.updateRoad(sunk.roadById(hw)!.copyWith(
          deck: RoadDeck(
              startM: -20,
              endM: -20,
              startOffsetM: -20,
              endOffsetM: -20,
              tunnels: [(0, len)])));
      final (a, b) = both(sunk, st2);
      expect(a, closeTo(b, 1e-12), reason: 'the tunnel adds nothing');
    });

    test('busy roads are louder', () {
      expect(RoadNoise.volumeFactor(1), greaterThan(RoadNoise.volumeFactor(0)));
      expect(RoadNoise.falloff(0), 1);
      expect(RoadNoise.falloff(RoadNoise.reachM), 0);
      expect(RoadNoise.taxFactor(RoadNoise.baseLandValue), closeTo(1, 1e-12));
      expect(RoadNoise.taxFactor(0), 0.85);
      expect(RoadNoise.taxFactor(1), 1.15);
      expect(RoadNoise.landValue(noise: 0, pollution: 1000),
          closeTo(RoadNoise.baseLandValue - RoadNoise.pollutionWeight, 1e-12));
    });
  });
}
