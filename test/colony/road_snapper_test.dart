// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_snapper.dart';
import 'package:flutter_test/flutter_test.dart';

/// The road tool's snapping: onto roads, round angles, the zoning grid and
/// guidelines — each switchable from the snapping menu.
void main() {
  CityLayout layoutWith(List<List<Vec2>> roads) {
    final l = CityLayout();
    for (final r in roads) {
      l.commitRoad(controls: r, regenerateLots: false);
    }
    return l;
  }

  void near(Vec2 a, Vec2 b, [double tol = 1e-6]) {
    expect(a.distanceTo(b), lessThan(tol), reason: '$a vs $b');
  }

  // A north-south street from the origin, 200 m long.
  final street = [const Vec2(0, 0), const Vec2(0, 200)];

  group('onto roads', () {
    test('the end of a road first, with which end and its heading', () {
      final s = RoadSnapper(layoutWith([street]))
          .snap(const Vec2(5, 204));
      expect(s.kind, RoadSnapKind.roadEnd);
      near(s.point, const Vec2(0, 200));
      expect(s.roadEndIsStart, isFalse);
      near(s.roadTangent!, const Vec2(0, 1));
      expect(s.onRoad, isTrue);
    });

    test('then anywhere along one', () {
      final s = RoadSnapper(layoutWith([street]))
          .snap(const Vec2(6, 100));
      expect(s.kind, RoadSnapKind.roadPoint);
      near(s.point, const Vec2(0, 100));
      expect(s.roadS, closeTo(100, 1e-6));
    });

    test('not when the menu says not', () {
      final s = RoadSnapper(layoutWith([street]),
              options: RoadSnapOptions.off)
          .snap(const Vec2(6, 100));
      expect(s.kind, RoadSnapKind.free);
      near(s.point, const Vec2(6, 100));
    });
  });

  group('round angles', () {
    test('square off the road being left', () {
      final snapper = RoadSnapper(layoutWith([street]),
          options: const RoadSnapOptions(
              roads: false, zoningGrid: false, guidelines: false));
      // Leaving the middle of the street, a couple of degrees off east.
      final s = snapper.snap(const Vec2(100, 103.5),
          from: const Vec2(0, 100));
      expect(s.kind, RoadSnapKind.angle);
      near(s.point, Vec2(0 + s.lengthM!, 100), 1e-6);
      expect(s.guides, isNotEmpty);
    });

    test('in 15 degree steps from the heading carried on', () {
      final snapper = RoadSnapper(CityLayout(),
          options: const RoadSnapOptions(
              roads: false, zoningGrid: false, guidelines: false));
      final s = snapper.snap(const Vec2(52, 88),
          from: const Vec2(0, 0), fromTangent: const Vec2(0, 1));
      // atan2(52, 88) ~ 30.6 degrees: onto 30.
      expect(s.kind, RoadSnapKind.angle);
      expect(s.angleRad!.abs(), closeTo(30 * 3.141592653589793 / 180, 1e-9));
    });

    test('leave a heading well off a round angle alone', () {
      final snapper = RoadSnapper(CityLayout(),
          options: const RoadSnapOptions(
              roads: false, zoningGrid: false, guidelines: false));
      final s = snapper.snap(const Vec2(40, 100),
          from: const Vec2(0, 0), fromTangent: const Vec2(0, 1));
      expect(s.kind, RoadSnapKind.free);
    });
  });

  group('the zoning grid', () {
    test('cuts a road into whole lots', () {
      final snapper = RoadSnapper(CityLayout(),
          options: const RoadSnapOptions(
              roads: false, angles: false, guidelines: false));
      final s = snapper.snap(const Vec2(0, 130), from: const Vec2(0, 0));
      // Two 12 m corner clearances and four 24 m lots.
      expect(s.kind, RoadSnapKind.grid);
      near(s.point, const Vec2(0, 120));
      expect(snapper.gridLength(5), 48, reason: 'never shorter than a lot');
    });

    test('puts a parallel road a whole block away', () {
      final snapper = RoadSnapper(layoutWith([street]),
          options: const RoadSnapOptions(
              roads: false, angles: false, guidelines: false));
      // Street half width 4 + new 4 + two rows of (3 m pavement + 32 m lot).
      final s = snapper.snap(const Vec2(80, 60));
      expect(s.kind, RoadSnapKind.guideline);
      near(s.point, const Vec2(78, 60));
    });
  });

  group('guidelines', () {
    test('carry a road on past its end', () {
      final snapper = RoadSnapper(layoutWith([street]),
          options: const RoadSnapOptions(
              roads: false, angles: false, zoningGrid: false));
      final s = snapper.snap(const Vec2(3, 300));
      expect(s.kind, RoadSnapKind.guideline);
      near(s.point, const Vec2(0, 300));
      expect(s.guides.single, hasLength(2));
    });

    test('cross a road\'s end square', () {
      final snapper = RoadSnapper(layoutWith([street]),
          options: const RoadSnapOptions(
              roads: false, angles: false, zoningGrid: false));
      final s = snapper.snap(const Vec2(120, 203));
      expect(s.kind, RoadSnapKind.guideline);
      near(s.point, const Vec2(120, 200));
    });

    test('meet where two cross', () {
      // A second street, east-west, whose extension crosses the first's.
      final snapper = RoadSnapper(
          layoutWith([
            street,
            [const Vec2(100, 300), const Vec2(300, 300)],
          ]),
          options: const RoadSnapOptions(
              roads: false, angles: false, zoningGrid: false));
      final s = snapper.snap(const Vec2(2, 302));
      expect(s.kind, RoadSnapKind.guidelineCross);
      near(s.point, const Vec2(0, 300));
      expect(s.guides, hasLength(2));
    });
  });

  test('a cursor in open country stays where it is', () {
    final s = RoadSnapper(CityLayout()).snap(const Vec2(7, 9));
    expect(s.kind, RoadSnapKind.free);
    near(s.point, const Vec2(7, 9));
  });
}
