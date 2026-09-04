// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/spatial_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BoxIndex', () {
    test('finds exactly the boxes within slack of a query, in insertion order',
        () {
      final idx = BoxIndex<String>(cellM: 10);
      idx.add('a', const Box2(0, 0, 5, 5));
      idx.add('b', const Box2(20, 20, 25, 25));
      idx.add('c', const Box2(7, 0, 9, 2));
      // Straddles many cells.
      idx.add('d', const Box2(-50, -50, 50, 50));

      expect(idx.near(const Box2(1, 1, 2, 2)), ['a', 'd']);
      expect(idx.near(const Box2(6, 0, 6.5, 1), 1.0), ['a', 'c', 'd']);
      expect(idx.near(const Box2(6, 0, 6.5, 1), 0.6), ['c', 'd']);
      expect(idx.near(const Box2(6, 0, 6.5, 1), 0.4), ['d']);
      expect(idx.near(const Box2(100, 100, 101, 101)), isEmpty);
      // A box that touches many cells still reports each item once.
      expect(idx.near(const Box2(-40, -40, 40, 40)), ['a', 'b', 'c', 'd']);
    });
  });

  group('SegmentIndex', () {
    RoadSpline straight(String id, Vec2 a, Vec2 b,
            {RoadClass cls = RoadClass.street}) =>
        RoadSpline(id: id, controls: [a, b], roadClass: cls);

    test('a long road is found by a query anywhere along it', () {
      final idx = SegmentIndex();
      idx.add(straight('h', const Vec2(-5000, 0), const Vec2(5000, 0)));
      idx.add(straight('v', const Vec2(0, -100), const Vec2(0, 100)));

      final far = idx.segmentsNear(const Box2(4000, -1, 4010, 1));
      expect(far.keys, [idx.slotOf('h')]);
      // Only the segments in the box's cells, not the road's five thousand.
      expect(far.values.single.length, lessThan(40));

      final middle = idx.slotsNear(const Box2(-1, -1, 1, 1));
      expect(middle, [idx.slotOf('h'), idx.slotOf('v')]);
    });

    test('nearest searches outward until something is in reach', () {
      final idx = SegmentIndex();
      idx.add(straight('r', const Vec2(3000, 0), const Vec2(3000, 100)));
      final hit = idx.nearest(const Vec2(0, 50))!;
      expect(hit.road.road.id, 'r');
      expect(hit.distance, closeTo(3000, 1e-6));
      expect(hit.point.e, closeTo(3000, 1e-6));
      expect(hit.point.n, closeTo(50, 1e-6));
      expect(SegmentIndex().nearest(const Vec2(0, 0)), isNull);
    });

    test('nearest picks the truly nearest road, not the first cell hit', () {
      final idx = SegmentIndex();
      // A road just outside the first search ring and a nearer one that a
      // wider ring reaches on the other side.
      idx.add(straight('a', const Vec2(70, -100), const Vec2(70, 100)));
      idx.add(straight('b', const Vec2(-66, -100), const Vec2(-66, 100)));
      expect(idx.nearest(const Vec2(0, 0), startM: 64)!.road.road.id, 'b');
    });

    test('removing a road drops its segments; re-adding replaces them', () {
      final idx = SegmentIndex();
      idx.add(straight('r', const Vec2(0, 0), const Vec2(200, 0)));
      expect(idx.slotsNear(const Box2(100, -1, 101, 1)), hasLength(1));
      idx.remove('r');
      expect(idx.slotsNear(const Box2(100, -1, 101, 1)), isEmpty);
      expect(idx.byId('r'), isNull);
      idx.add(straight('r', const Vec2(0, 50), const Vec2(200, 50)));
      expect(idx.slotsNear(const Box2(100, -1, 101, 1)), isEmpty);
      expect(idx.slotsNear(const Box2(100, 49, 101, 51)), hasLength(1));
    });

    test('samples carry the arc length the crossing test needs', () {
      final idx = SegmentIndex();
      idx.add(straight('r', const Vec2(0, 0), const Vec2(100, 0)));
      final r = idx.byId('r')!;
      expect(r.lengthM, closeTo(100, 1e-6));
      expect(r.arcAt(r.segmentCount, 1.0), closeTo(100, 1e-6));
      expect(r.distanceTo(const Vec2(50, 7)), closeTo(7, 1e-6));
    });
  });
}
