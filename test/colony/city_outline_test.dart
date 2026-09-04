// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bodies =
      RealSolarSystem.build().all.where((b) => !b.isStar).toList();

  (CitySim, CityShape) build(CityGenSpec spec) {
    final b = CityBuild(spec, bodies: bodies);
    for (final _ in b.run()) {}
    return (b.city!, b.shape!);
  }

  group('CityShape', () {
    test('at taper 0 the outline IS the grid rectangle', () {
      final shape = CityShape.of(
          const CityGenSpec(blocksAcross: 4, taper: 0), math.Random(3));
      // Along the axes the reach is the half extent; on the diagonal it is
      // the corner.
      expect(shape.radiusAt(0), closeTo(shape.halfW, 1e-9));
      expect(shape.radiusAt(math.pi / 2), closeTo(shape.halfD, 1e-9));
      final corner = math.atan2(shape.halfD, shape.halfW);
      expect(shape.radiusAt(corner),
          closeTo(math.sqrt(shape.halfW * shape.halfW + shape.halfD * shape.halfD), 1e-6));
    });

    test('at taper 1 the corners go and the edge is ragged but bounded', () {
      final shape =
          CityShape.of(const CityGenSpec(blocksAcross: 4), math.Random(3));
      final corner = math.atan2(shape.halfD, shape.halfW);
      final cornerReach =
          math.sqrt(shape.halfW * shape.halfW + shape.halfD * shape.halfD);
      expect(shape.radiusAt(corner), lessThan(cornerReach * 0.9));
      for (var i = 0; i < 64; i++) {
        final r = shape.radiusAt(i / 64 * 2 * math.pi);
        expect(r, inInclusiveRange(shape.round * 0.78, shape.round * 1.22));
      }
    });
  });

  group('a generated town', () {
    late CitySim city;
    late CityShape shape;
    setUpAll(() {
      // No sprawl: this is the colony whose OWN outskirts — trunk roads
      // and farms — are under test. With sprawl, the interstates and the
      // farmland sections take their place.
      final (c, s) =
          build(const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 0));
      city = c;
      shape = s;
    });

    test('no street lot lies past the outline', () {
      var n = 0;
      for (final lot in city.layout.autoParcels) {
        expect(shape.fractionOf(lot.centroid), lessThan(1.08),
            reason: 'lot ${lot.id} is outside the outline');
        n++;
      }
      expect(n, greaterThan(100));
    });

    test('the corners of the grid are not built', () {
      final corner = math.sqrt(shape.halfW * shape.halfW + shape.halfD * shape.halfD);
      final far = city.layout.autoParcels
          .where((l) => l.centroid.length > corner * 0.92)
          .length;
      expect(far, 0);
    });

    test('trunk roads run out of town, plat nothing, and carry the farms', () {
      final trunks =
          city.layout.roads.where((r) => r.roadClass == RoadClass.trunk).toList();
      expect(trunks, isNotEmpty);
      var farthest = 0.0;
      for (final t in trunks) {
        for (final p in t.sample(stepM: 50)) {
          farthest = math.max(farthest, p.length);
        }
      }
      expect(farthest, greaterThan(shape.round + 3000));
      // Farms are manual plots past the outskirts, each within reach of a road.
      final farms = city.parcelBuildings.entries
          .where((e) => e.value.type == 'farm' || e.value.type == 'wind')
          .toList();
      expect(farms.length, greaterThanOrEqualTo(3));
      for (final e in farms) {
        final lot = city.parcelById(e.key)!;
        expect(lot.manual, isTrue);
        expect(shape.fractionOf(lot.centroid), greaterThan(1.2));
        expect(city.layout.distanceToCurb(lot.centroid),
            lessThan(math.max(e.value.siteWidthM, e.value.siteDepthM)));
      }
    });

    test('the railway passes clear of every street, with both its ends', () {
      final rails =
          city.layout.roads.where((r) => r.roadClass == RoadClass.rail).toList();
      expect(rails, isNotEmpty);
      final side = math.sin(shape.railBearing).sign;
      for (final r in rails) {
        for (final p in r.sample(stepM: 50)) {
          // Same side of town, and past the last street on that bearing.
          expect(p.n.sign, side);
          expect(p.n.abs(), greaterThan(shape.reachToward(shape.railBearing)));
        }
      }
      final types = city.parcelBuildings.values.map((s) => s.type).toSet();
      expect(types, contains('station'));
      expect(types, contains('freightyard'));
      // Both sit between the line and the town.
      for (final e in city.parcelBuildings.entries) {
        if (e.value.type != 'station' && e.value.type != 'freightyard') continue;
        final c = city.parcelById(e.key)!.centroid;
        expect(c.n.sign, side);
        expect(shape.fractionOf(c), greaterThan(1.0));
      }
    });

    test('industry clusters on the railway side, houses on the others', () {
      var worksSide = 0, otherSide = 0, worksTotal = 0, otherTotal = 0;
      for (final e in city.parcelBuildings.entries) {
        if (e.value.claimsOwnSite) continue;
        final lot = city.parcelById(e.key);
        if (lot == null) continue;
        final t = shape.fractionOf(lot.centroid);
        if (t < 0.8) continue;
        final bearing = math.atan2(lot.centroid.n, lot.centroid.e);
        final d = (bearing - shape.railBearing).abs();
        final near = math.min(d, 2 * math.pi - d) < 0.75;
        final industrial = e.value.type.startsWith('i-');
        if (near) {
          worksTotal++;
          if (industrial) worksSide++;
        } else {
          otherTotal++;
          if (industrial) otherSide++;
        }
      }
      expect(worksTotal, greaterThan(5));
      expect(otherTotal, greaterThan(5));
      expect(worksSide / worksTotal, greaterThan(otherSide / otherTotal));
    });
  });

  test('taper 0 and no outskirts reproduces a full square grid', () {
    final (city, shape) = build(const CityGenSpec(
        blocksAcross: 3, taper: 0, outreachM: 0, farms: 0, railway: false));
    final corner = math.sqrt(shape.halfW * shape.halfW + shape.halfD * shape.halfD);
    final far = city.layout.autoParcels
        .where((l) => l.centroid.length > corner * 0.8)
        .length;
    expect(far, greaterThan(0), reason: 'the square should keep its corners');
    expect(city.layout.roads.any((r) => r.roadClass == RoadClass.trunk), isFalse);
    expect(city.layout.roads.any((r) => r.roadClass == RoadClass.rail), isFalse);
  });
}
