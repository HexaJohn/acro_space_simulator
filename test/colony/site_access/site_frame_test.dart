// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_frame.dart';
import 'package:acro_space_simulator/domain/colony/city/spatial_index.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The site frame (docs/plans/site-access.md §3.1, slice R-F).
///
/// Nothing a lot stores is trusted: winding, frontage order and the frontage
/// itself are normalised, so every generator after this one can assume x runs
/// along the street and y runs into the lot.
void main() {
  const tol = 1e-9;

  SegmentIndex roadsOf(List<RoadSpline> roads) {
    final idx = SegmentIndex();
    for (final r in roads) {
      idx.add(r);
    }
    return idx;
  }

  RoadSpline street(
    String id,
    Vec2 a,
    Vec2 b, [
    RoadClass c = RoadClass.street,
  ]) => RoadSpline(id: id, controls: [a, b], roadClass: c);

  void expectVec(Vec2 actual, Vec2 expected, {double eps = 1e-9}) {
    expect(actual.e, closeTo(expected.e, eps), reason: '$actual vs $expected');
    expect(actual.n, closeTo(expected.n, eps), reason: '$actual vs $expected');
  }

  double signedArea(List<Vec2> p) {
    var s = 0.0;
    for (var i = 0; i < p.length; i++) {
      s += p[i].cross(p[(i + 1) % p.length]);
    }
    return s / 2;
  }

  /// Heading difference folded into (−π, π].
  double headingGap(double a, double b) {
    var d = (a - b) % (2 * math.pi);
    if (d > math.pi) d -= 2 * math.pi;
    return d;
  }

  final empty = SegmentIndex();

  group('eligible join roads (§3.2)', () {
    test('exactly the at-grade car roads that front lots, plus the alley', () {
      final eligible = {
        for (final c in RoadClass.values)
          if (isEligibleJoinRoad(c)) c,
      };
      expect(eligible, {
        RoadClass.street,
        RoadClass.avenue,
        RoadClass.highway,
        RoadClass.path,
        RoadClass.alley,
        RoadClass.streetOneWay,
        RoadClass.boulevard,
      });
    });

    test('the reach constant is the road graph manual reach', () {
      expect(kSiteReachM, RoadGraph.manualReachM);
    });
  });

  group('winding and frontage order', () {
    const ccw = [Vec2(0, 0), Vec2(20, 0), Vec2(20, 30), Vec2(0, 30)];
    final cw = ccw.reversed.toList();
    const front = (Vec2(0, 0), Vec2(20, 0));
    const backwards = (Vec2(20, 0), Vec2(0, 0));

    test('both windings and both frontage orders give one frame', () {
      for (final poly in [ccw, cw]) {
        for (final f in [front, backwards]) {
          final frame = SiteFrame.of(poly, f, empty)!;
          expectVec(frame.origin, const Vec2(0, 0));
          expectVec(frame.u, const Vec2(1, 0));
          expectVec(frame.v, const Vec2(0, 1));
          expect(frame.widthM, closeTo(20, tol));
          expect(frame.usedEffectiveFrontage, isFalse);
          expect(frame.streetHeading, closeTo(math.pi, tol));
        }
      }
    });

    test('v = u.perp (right-handed) and points at the interior', () {
      final frame = SiteFrame.of(cw, backwards, empty)!;
      expectVec(frame.v, frame.u.perp);
      expect((interiorPoint(cw) - frame.origin).dot(frame.v), greaterThan(0));
    });

    test('toLocal and toWorld are inverse; the frontage is y = 0', () {
      final frame = SiteFrame.of(
        const [Vec2(3, 4), Vec2(23, 19), Vec2(5, 43), Vec2(-15, 28)],
        (const Vec2(23, 19), const Vec2(3, 4)),
        empty,
      )!;
      expectVec(frame.toLocal(frame.origin), const Vec2(0, 0));
      expectVec(
        frame.toLocal(frame.origin + frame.u * frame.widthM),
        Vec2(frame.widthM, 0),
      );
      for (final p in const [Vec2(10, 10), Vec2(-7, 31), Vec2(100, -3)]) {
        expectVec(frame.toWorld(frame.toLocal(p)), p);
      }
      expect(frame.widthM, closeTo(25, tol));
      expect(frame.toLocal(const Vec2(5, 43)).n, greaterThan(0));
    });

    test('buildingHeading = streetHeading + π, spinning local +Y onto v', () {
      final frame = SiteFrame.of(
        const [Vec2(3, 4), Vec2(23, 19), Vec2(5, 43), Vec2(-15, 28)],
        (const Vec2(3, 4), const Vec2(23, 19)),
        empty,
      )!;
      expect(
        frame.buildingHeading - frame.streetHeading,
        closeTo(math.pi, tol),
      );
      // Parcel.heading convention: heading h is the direction (sin h, cos h).
      final h = frame.buildingHeading;
      expectVec(Vec2(math.sin(h), math.cos(h)), frame.v, eps: 1e-12);
      final s = frame.streetHeading;
      expectVec(Vec2(math.sin(s), math.cos(s)), frame.v * -1, eps: 1e-12);
    });
  });

  group('the starter kit', () {
    late CitySim city;
    setUpAll(() {
      city = CityStarterKit.found(
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        config: const CityConfig(bodyId: 'earth', gridSize: 20),
      );
    });

    test('pad and solar frontages run backwards; the frame turns them', () {
      final manual = city.layout.manualParcels;
      expect(manual.length, 4);
      final roads = city.layout.roadIndex;
      // Spaceport, solar farm, farm, pump, in placement order.
      final expected = <(Vec2, Vec2, double, bool)>[
        (const Vec2(60, 960), const Vec2(1, 0), 900, true),
        (const Vec2(60, -60), const Vec2(1, 0), 780, true),
        (const Vec2(-60, -460), const Vec2(-1, 0), 400, false),
        (const Vec2(-60, 60), const Vec2(-1, 0), 180, false),
      ];
      for (var i = 0; i < 4; i++) {
        final lot = manual[i];
        final (origin, v, w, reversed) = expected[i];
        final f = lot.frontage!;
        // The trap itself: the stored direction's CCW normal points at the
        // street for the pad and the solar farm.
        final storedNormal = (f.$2 - f.$1).normalized.perp;
        expect(
          (lot.centroid - f.$1).dot(storedNormal) < 0,
          reversed,
          reason: lot.id,
        );

        final frame = SiteFrame.of(lot.polygon, lot.frontage, roads)!;
        expectVec(frame.origin, origin);
        expectVec(frame.v, v);
        expect(frame.widthM, closeTo(w, tol));
        expect(frame.usedEffectiveFrontage, isFalse);
        expect(
          headingGap(frame.streetHeading, lot.heading),
          closeTo(0, tol),
          reason: '${lot.id}: Parcel.facing == −v here',
        );
      }
    });

    test('the CW l-side auto lots get the same inward frame as the r side', () {
      final roads = city.layout.roadIndex;
      final lots = city.layout.autoParcels;
      final cwLots = lots.where((p) => signedArea(p.polygon) < 0).toList();
      expect(cwLots, isNotEmpty, reason: 'the plat winds l lots clockwise');
      expect(cwLots.every((p) => p.id.contains('-l')), isTrue);

      var compared = 0;
      for (final lot in lots) {
        final frame = SiteFrame.of(lot.polygon, lot.frontage, roads)!;
        final flipped = SiteFrame.of(
          lot.polygon.reversed.toList(),
          lot.frontage,
          roads,
        )!;
        expectVec(flipped.origin, frame.origin);
        expectVec(flipped.u, frame.u);
        expect(frame.usedEffectiveFrontage, isFalse);
        expect(frame.widthM, closeTo(lot.frontageWidth, 1e-9));
        // Every corner lies on the lot side of the frontage line.
        for (final p in lot.polygon) {
          expect(frame.toLocal(p).n, greaterThan(-1e-6), reason: lot.id);
        }
        expect(frame.toLocal(lot.centroid).n, greaterThan(0), reason: lot.id);
        final road = city.layout.roadIndex.byId(lot.roadId!)!;
        expect(
          road.distanceTo(frame.origin),
          lessThan(road.distanceTo(lot.centroid)),
          reason: '${lot.id}: y = 0 is the street side',
        );
        if (lot.facing.dot(frame.v * -1) > 1 - 1e-12) {
          expect(
            headingGap(frame.streetHeading, lot.heading),
            closeTo(0, 1e-6),
            reason: lot.id,
          );
          compared++;
        }
      }
      expect(compared, greaterThan(lots.length ~/ 2));
    });

    test('buildableExtent and inscribedExtent do not depend on winding', () {
      final samples = [
        ...city.layout.manualParcels,
        ...city.layout.autoParcels.where((p) => signedArea(p.polygon) < 0),
      ];
      for (final lot in samples) {
        final flipped = Parcel(
          id: lot.id,
          polygon: lot.polygon.reversed.toList(),
          roadId: lot.roadId,
          frontage: lot.frontage,
          sideStreet: lot.sideStreet,
          manual: lot.manual,
        );
        expect(
          flipped.buildableExtent.width,
          closeTo(lot.buildableExtent.width, 1e-9),
        );
        expect(
          flipped.buildableExtent.depth,
          closeTo(lot.buildableExtent.depth, 1e-9),
        );
        expect(
          flipped.inscribedExtent.width,
          closeTo(lot.inscribedExtent.width, 1e-9),
        );
        expect(
          flipped.inscribedExtent.depth,
          closeTo(lot.inscribedExtent.depth, 1e-9),
        );
      }
    });
  });

  group('effective frontage', () {
    const square = [Vec2(10, 10), Vec2(50, 10), Vec2(50, 50), Vec2(10, 50)];

    test('a frontage-less manual lot fronts the road beside it', () {
      final roads = roadsOf([
        street('w', const Vec2(0, -100), const Vec2(0, 100)),
      ]);
      final f = effectiveFrontage(square, roads)!;
      expectVec(f.$1, const Vec2(10, 50));
      expectVec(f.$2, const Vec2(10, 10));

      final frame = SiteFrame.of(square, null, roads)!;
      expect(frame.usedEffectiveFrontage, isTrue);
      expectVec(frame.origin, const Vec2(10, 50));
      expectVec(frame.v, const Vec2(1, 0));
      expect(frame.widthM, closeTo(40, tol));
      expect(frame.streetHeading, closeTo(-math.pi / 2, tol));
      expect(frame.buildingHeading, closeTo(math.pi / 2, tol));
    });

    test('a grid cell fronts its real road, not its fake north edge', () {
      // parcelForCell's shape: a square that stores its north edge.
      const cell = [Vec2(0, 0), Vec2(30, 0), Vec2(30, 30), Vec2(0, 30)];
      final roads = roadsOf([
        street('s', const Vec2(-80, -8), const Vec2(120, -8)),
      ]);
      final frame = SiteFrame.of(cell, null, roads)!;
      expect(frame.usedEffectiveFrontage, isTrue);
      expectVec(frame.origin, const Vec2(0, 0));
      expectVec(frame.u, const Vec2(1, 0));
      expectVec(frame.v, const Vec2(0, 1));
    });

    test('a stored frontage whose midpoint is off the polygon is replaced', () {
      final roads = roadsOf([
        street('w', const Vec2(0, -100), const Vec2(0, 100)),
      ]);
      // 0.9 m off: trusted.
      final near = SiteFrame.of(square, (
        const Vec2(10, 50.9),
        const Vec2(50, 50.9),
      ), roads)!;
      expect(near.usedEffectiveFrontage, isFalse);
      expectVec(near.v, const Vec2(0, -1));
      // 5 m off: replaced by the edge facing the road.
      final off = SiteFrame.of(square, (
        const Vec2(10, 55),
        const Vec2(50, 55),
      ), roads)!;
      expect(off.usedEffectiveFrontage, isTrue);
      expectVec(off.v, const Vec2(1, 0));
    });

    test('a parallel road beats a nearer road that meets the lot end-on', () {
      final roads = roadsOf([
        // End-on to the south edge, 12 m away: score 12.
        street('q', const Vec2(30, -80), const Vec2(30, -2)),
        // Parallel to the north edge, 24 m away: score 24 − 15 = 9.
        street('p', const Vec2(-50, 74), const Vec2(110, 74)),
      ]);
      final f = effectiveFrontage(square, roads)!;
      expectVec(f.$1, const Vec2(50, 50));
      expectVec(f.$2, const Vec2(10, 50));
    });

    test('an exact tie goes to the smaller canonical edge index', () {
      // Two parallel roads 60 m off the south and west edges, as at the
      // spaceport: the south edge starts at the smallest (e, n) vertex.
      const pad = [Vec2(60, 60), Vec2(960, 60), Vec2(960, 960), Vec2(60, 960)];
      final roads = roadsOf([
        street('ns', const Vec2(0, 0), const Vec2(0, 300)),
        street('ew', const Vec2(0, 0), const Vec2(300, 0)),
      ]);
      const south = (Vec2(60, 60), Vec2(960, 60));
      for (final poly in [
        pad,
        pad.reversed.toList(),
        [pad[2], pad[3], pad[0], pad[1]],
      ]) {
        final f = effectiveFrontage(poly, roads)!;
        expectVec(f.$1, south.$1);
        expectVec(f.$2, south.$2);
      }
    });

    test('only eligible roads, within reach, outside the edge, count', () {
      // Out of reach: 100 m > 90 + 4.
      expect(
        effectiveFrontage(
          square,
          roadsOf([street('far', const Vec2(-90, -100), const Vec2(-90, 100))]),
        ),
        isNull,
      );
      // In reach but a motorway, a ramp, a railway: nothing.
      for (final c in [RoadClass.motorway, RoadClass.ramp, RoadClass.rail]) {
        expect(
          effectiveFrontage(
            square,
            roadsOf([street('x', const Vec2(0, -100), const Vec2(0, 100), c)]),
          ),
          isNull,
          reason: c.name,
        );
      }
      // A road straight through the lot fronts no edge.
      expect(
        effectiveFrontage(
          square,
          roadsOf([street('thru', const Vec2(30, -100), const Vec2(30, 100))]),
        ),
        isNull,
      );
      // Nor does one crossing a corner at a shallow angle, although its
      // nearest vertex projection lies just outside the south edge.
      expect(
        effectiveFrontage(
          square,
          roadsOf([
            street('skew', const Vec2(-100, 6.875), const Vec2(100, 12.375)),
          ]),
        ),
        isNull,
      );
      // Edges under 6 m are never candidates.
      const sliver = [Vec2(0, 0), Vec2(5, 0), Vec2(5, 5), Vec2(0, 5)];
      expect(
        effectiveFrontage(
          sliver,
          roadsOf([street('s', const Vec2(-50, -4), const Vec2(50, -4))]),
        ),
        isNull,
      );
    });

    test('no road in reach: the longest edge, flagged effective', () {
      const lot = [Vec2(0, 0), Vec2(40, 0), Vec2(40, 10), Vec2(0, 10)];
      final frame = SiteFrame.of(lot, null, empty)!;
      expect(frame.usedEffectiveFrontage, isTrue);
      expect(frame.widthM, closeTo(40, tol));
      expectVec(frame.origin, const Vec2(0, 0));
      expectVec(frame.v, const Vec2(0, 1));
    });
  });

  group('degenerate polygons have no frame', () {
    test('too few vertices, no area, a zero frontage, non-finite', () {
      expect(
        SiteFrame.of(const [Vec2(0, 0), Vec2(10, 0)], null, empty),
        isNull,
      );
      expect(
        SiteFrame.of(const [Vec2(0, 0), Vec2(10, 0), Vec2(20, 0)], null, empty),
        isNull,
      );
      // 29 m² is under the plat's own 30 m² floor.
      expect(
        SiteFrame.of(
          const [Vec2(0, 0), Vec2(29, 0), Vec2(29, 1), Vec2(0, 1)],
          null,
          empty,
        ),
        isNull,
      );
      expect(
        SiteFrame.of(
          const [Vec2(0, 0), Vec2(30, 0), Vec2(30, 1), Vec2(0, 1)],
          null,
          empty,
        ),
        isNotNull,
      );
      const rect = [Vec2(0, 0), Vec2(20, 0), Vec2(20, 30), Vec2(0, 30)];
      expect(
        SiteFrame.of(rect, (const Vec2(10, 0), const Vec2(10, 0)), empty),
        isNull,
      );
      expect(
        SiteFrame.of(
          const [Vec2(0, 0), Vec2(double.nan, 0), Vec2(0, 30)],
          null,
          empty,
        ),
        isNull,
      );
    });
  });

  group('interior point', () {
    test('a convex lot: the vertex average', () {
      expectVec(
        interiorPoint(const [
          Vec2(0, 0),
          Vec2(20, 0),
          Vec2(20, 30),
          Vec2(0, 30),
        ]),
        const Vec2(10, 15),
      );
    });

    test('an L lot: the longest horizontal chord through the average', () {
      const l = [
        Vec2(0, 0), Vec2(30, 0), Vec2(30, 5), //
        Vec2(5, 5), Vec2(5, 30), Vec2(0, 30),
      ];
      final avgN = 70 / 6;
      expectVec(interiorPoint(l), Vec2(2.5, avgN));
      expectVec(interiorPoint(l.reversed.toList()), Vec2(2.5, avgN));
    });

    test('a U lot: equal chords go west; the frame still points inward', () {
      const u = [
        Vec2(0, 0), Vec2(30, 0), Vec2(30, 30), Vec2(20, 30), //
        Vec2(20, 10), Vec2(10, 10), Vec2(10, 30), Vec2(0, 30),
      ];
      expectVec(interiorPoint(u), const Vec2(5, 17.5));
      // A frontage stored along the south edge, backwards.
      final frame = SiteFrame.of(u.reversed.toList(), (
        const Vec2(30, 0),
        const Vec2(0, 0),
      ), empty)!;
      expectVec(frame.origin, const Vec2(0, 0));
      expectVec(frame.v, const Vec2(0, 1));
    });
  });

  group('depth profile', () {
    const rect = [Vec2(0, 0), Vec2(20, 0), Vec2(20, 30), Vec2(0, 30)];

    test('a rectangle: its depth less the margin, nothing outside it', () {
      final p = SiteFrame.of(rect, (
        const Vec2(20, 0),
        const Vec2(0, 0),
      ), empty)!.profile;
      expect(p.depthAt(10), closeTo(30 - kDepthProfileMarginM, 1e-9));
      expect(p.depthAt(0.1), closeTo(29.7, 1e-9));
      expect(p.depthAt(19.9), closeTo(29.7, 1e-9));
      expect(p.depthAt(-0.1), 0);
      expect(p.depthAt(20.1), 0);
      expect(p.maxDepthM, closeTo(29.7, 1e-9));
      expect(p.containsRect(const SiteRect(1, 1, 19, 29)), isTrue);
      expect(p.containsRect(const SiteRect(1, 1, 21, 29)), isFalse);
      expect(p.containsRect(const SiteRect(1, -1, 19, 29)), isFalse);
      expect(
        p.containsRect(const SiteRect(5, 5, 5, 9)),
        isFalse,
        reason: 'empty rectangle',
      );
    });

    test('the profile is built once, on first read', () {
      final frame = SiteFrame.of(rect, null, empty)!;
      expect(identical(frame.profile, frame.profile), isTrue);
    });

    test('a C lot keeps the interval nearest the frontage', () {
      const c = [
        Vec2(0, 0), Vec2(30, 0), Vec2(30, 10), Vec2(10, 10), //
        Vec2(10, 20), Vec2(30, 20), Vec2(30, 30), Vec2(0, 30),
      ];
      final p = SiteFrame.of(c, (
        const Vec2(0, 0),
        const Vec2(30, 0),
      ), empty)!.profile;
      expect(p.depthAt(5), closeTo(29.7, 1e-9));
      expect(p.depthAt(20), closeTo(9.7, 1e-9));
    });

    test('exact containment: corners inside is not enough on a U lot', () {
      const u = [
        Vec2(0, 0), Vec2(30, 0), Vec2(30, 30), Vec2(20, 30), //
        Vec2(20, 10), Vec2(10, 10), Vec2(10, 30), Vec2(0, 30),
      ];
      final p = SiteFrame.of(u, (
        const Vec2(0, 0),
        const Vec2(30, 0),
      ), empty)!.profile;
      // All four corners stand in the arms; the top edge crosses the notch.
      expect(p.containsRect(const SiteRect(2, 20, 28, 25)), isFalse);
      expect(p.containsRect(const SiteRect(2, 2, 28, 8)), isTrue);
      expect(p.containsRect(const SiteRect(2, 12, 8, 28)), isTrue);
      expect(p.depthAt(15), closeTo(9.7, 1e-9));
      expect(p.depthAt(25), closeTo(29.7, 1e-9));
    });

    test('a triangle tapers', () {
      const tri = [Vec2(0, 0), Vec2(40, 0), Vec2(0, 40)];
      final p = SiteFrame.of(tri, (
        const Vec2(0, 0),
        const Vec2(40, 0),
      ), empty)!.profile;
      expect(p.depthAt(10), greaterThan(p.depthAt(30)));
      expect(p.depthAt(30.25), closeTo(40 - 30.25 - 0.3, 1e-9));
      expect(p.containsRect(const SiteRect(1, 1, 30, 20)), isFalse);
      expect(p.containsRect(const SiteRect(1, 1, 15, 20)), isTrue);
    });
  });
}
