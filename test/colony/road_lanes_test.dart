// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

/// A road's class is the ONE description of its cross-section: the width
/// the enum carries, the lanes the renderer paints and the lanes the
/// traffic pass fills all come from the same layout.
void main() {
  group('the lane layouts', () {
    test('every class with lanes is exactly as wide as its lanes add up to',
        () {
      for (final cls in RoadClass.values) {
        final lanes = cls.lanes;
        if (lanes == null) continue;
        expect(lanes.widthM, closeTo(cls.width, 1e-9),
            reason: '${cls.name}: ${lanes.widthM} vs ${cls.width}');
      }
    });

    test('the expressways are four, six and eight lanes, divided, with '
        'shoulders and a barrier', () {
      expect(RoadClass.expressway4.lanes!.laneCount, 4);
      expect(RoadClass.expressway6.lanes!.laneCount, 6);
      expect(RoadClass.expressway8.lanes!.laneCount, 8);
      for (final cls in [
        RoadClass.expressway4,
        RoadClass.expressway6,
        RoadClass.expressway8
      ]) {
        final l = cls.lanes!;
        expect(l.divided, isTrue);
        expect(l.median, MedianStyle.barrier);
        expect(l.edgeLines, isTrue);
        expect(cls.isExpressway, isTrue);
        expect(cls.limitedAccess, isTrue);
        expect(cls.platsLots, isFalse, reason: 'nothing fronts an expressway');
        expect(cls.hasPavement, isFalse);
        expect(cls.paved, isTrue);
        expect(cls.carriesCars, isTrue);
        expect(cls.joinsJunctions, isTrue);
      }
      // Wider with every pair of lanes, by exactly two lanes.
      expect(RoadClass.expressway6.width - RoadClass.expressway4.width,
          closeTo(2 * 3.6, 1e-9));
      expect(RoadClass.expressway8.width - RoadClass.expressway6.width,
          closeTo(2 * 3.6, 1e-9));
    });

    test('a ramp is one lane, one way, and its lane straddles the centreline',
        () {
      final ramp = RoadClass.ramp;
      expect(ramp.oneWay, isTrue);
      expect(ramp.lanes!.oneWay, isTrue);
      expect(ramp.lanes!.laneCount, 1);
      expect(ramp.lanes!.laneOffsets, [closeTo(0, 1e-9)]);
      expect(ramp.platsLots, isFalse);
      expect(ramp.hasPavement, isFalse);
      expect(ramp.joinsJunctions, isTrue, reason: 'a ramp terminal is a T');
      expect(ramp.limitedAccess, isFalse);
      // Edge lines both sides, nothing down the middle.
      final lines = ramp.lanes!.lineOffsets;
      expect(lines.length, 2);
      expect(lines.every((l) => l.line == LaneLine.solidWhite), isTrue);
    });

    test('lane centres sit to the right of the centreline, one per lane, '
        'clear of the median', () {
      final l = RoadClass.expressway8.lanes!;
      expect(l.laneOffsets.length, 4);
      for (final o in l.laneOffsets) {
        expect(o, greaterThan(l.medianM / 2));
        expect(o, lessThan(l.halfWidthM - l.shoulderM));
      }
      // A street: one lane each way, two metres off the centreline.
      expect(RoadClass.street.lanes!.laneOffsets, [closeTo(2.0, 1e-9)]);
    });

    test('the paint follows the class', () {
      // A street: one dashed yellow down the middle, nothing else.
      final street = RoadClass.street.lanes!.lineOffsets;
      expect(street.length, 1);
      expect(street.single.line, LaneLine.dashedYellow);
      expect(street.single.offset, 0);
      // An avenue: a double yellow and a dash each way.
      final avenue = RoadClass.avenue.lanes!.lineOffsets;
      expect(avenue.where((l) => l.line == LaneLine.solidYellow).length, 2);
      expect(avenue.where((l) => l.line == LaneLine.dashedWhite).length, 2);
      // An eight-lane expressway: a yellow at each median edge, three
      // dashes each way, a white edge line each side.
      final eight = RoadClass.expressway8.lanes!.lineOffsets;
      expect(eight.where((l) => l.line == LaneLine.solidYellow).length, 2);
      expect(eight.where((l) => l.line == LaneLine.dashedWhite).length, 6);
      expect(eight.where((l) => l.line == LaneLine.solidWhite).length, 2);
      // Symmetric: every offset has its mirror.
      for (final l in eight) {
        expect(eight.any((m) => (m.offset + l.offset).abs() < 1e-9), isTrue);
      }
      // No lanes to paint on a track or a railway.
      expect(RoadClass.path.lanes, isNull);
      expect(RoadClass.alley.lanes, isNull);
      expect(RoadClass.rail.lanes, isNull);
      expect(RoadClass.transit.lanes, isNull);
    });
  });

  test('the new classes are APPENDED: saves persist the enum by index', () {
    expect(RoadClass.rail.index, 8);
    expect(RoadClass.expressway4.index, 9);
    expect(RoadClass.expressway6.index, 10);
    expect(RoadClass.expressway8.index, 11);
    expect(RoadClass.ramp.index, 12);
  });

  test('what joins a junction', () {
    expect(RoadClass.street.joinsJunctions, isTrue);
    expect(RoadClass.avenue.joinsJunctions, isTrue);
    expect(RoadClass.trunk.joinsJunctions, isTrue,
        reason: 'an artery meets the county grid at a signal');
    expect(RoadClass.alley.joinsJunctions, isFalse);
    expect(RoadClass.path.joinsJunctions, isFalse);
    expect(RoadClass.elevated.joinsJunctions, isFalse, reason: 'in the air');
    expect(RoadClass.transit.joinsJunctions, isFalse);
    expect(RoadClass.rail.joinsJunctions, isFalse);
  });
}
