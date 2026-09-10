// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/scatter/scatter_mask.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

/// The gate that keeps trees out of buildings.
void main() {
  const groundR = 6371000.0;

  /// A body-fixed direction [east]/[north] metres from the site at (0,0).
  Vector3 dirAt(double east, double north) =>
      Vector3(groundR, east, north).normalized;

  Vector3 pointAt(double east, double north) => dirAt(east, north) * groundR;

  ScatterMaskBuilder builder() => ScatterMaskBuilder(
        originBF: Vector3(groundR, 0, 0),
        groundRadiusM: groundR,
      );

  test('a disc blocks its own site and nothing beyond it', () {
    final b = builder()..addDisc(pointAt(0, 0), 50);
    final mask = b.build(1);

    expect(mask.blocks(dirAt(0, 0)), isTrue);
    expect(mask.blocks(dirAt(40, 0)), isTrue);
    expect(mask.blocks(dirAt(0, -49)), isTrue);
    expect(mask.blocks(dirAt(60, 0)), isFalse);
    expect(mask.blocks(dirAt(0, 200)), isFalse);
  });

  test('a corridor blocks along its length, not around its ends', () {
    final b = builder()
      ..addCapsule(pointAt(0, -300), pointAt(0, 300), 10);
    final mask = b.build(1);

    for (final n in [-280.0, -100.0, 0.0, 150.0, 290.0]) {
      expect(mask.blocks(dirAt(0, n)), isTrue, reason: 'on the road at $n');
      expect(mask.blocks(dirAt(9, n)), isTrue, reason: 'in the verge at $n');
      expect(mask.blocks(dirAt(25, n)), isFalse, reason: 'clear at $n');
    }
    // Past the end of the run, only the cap reaches.
    expect(mask.blocks(dirAt(0, 305)), isTrue);
    expect(mask.blocks(dirAt(0, 340)), isFalse);
  });

  test('a candidate on the far side of the planet is not blocked', () {
    final mask = (builder()..addDisc(pointAt(0, 0), 400)).build(1);
    expect(mask.blocks(const Vector3(-1, 0, 0)), isFalse);
    expect(mask.blocks(const Vector3(0, 1, 0)), isFalse);
  });

  test('an empty mask blocks nothing', () {
    final mask = builder().build(1);
    expect(mask.isEmpty, isTrue);
    expect(mask.blocks(dirAt(0, 0)), isFalse);
  });

  test('relief across the footprint does not let candidates through', () {
    // The whole reason the test is flattened into the tangent plane: a 900 m
    // pad on a slope spans a hundred metres of elevation, and a 3D distance
    // test would pass anything standing at its high end.
    final high = dirAt(0, 0) * (groundR + 120);
    final mask = (builder()..addDisc(high, 450)).build(1);
    expect(mask.blocks(dirAt(0, 0)), isTrue);
    expect(mask.blocks(dirAt(300, 200)), isTrue);
    expect(mask.blocks(dirAt(900, 0)), isFalse);
  });

  test('many features stay cheap — the grid is consulted, not the list', () {
    final b = builder();
    // A town's worth of corridors laid on a grid.
    for (var i = -20; i <= 20; i++) {
      b.addCapsule(pointAt(i * 60.0, -1200), pointAt(i * 60.0, 1200), 8);
      b.addCapsule(pointAt(-1200, i * 60.0), pointAt(1200, i * 60.0), 8);
    }
    final mask = b.build(1);
    expect(mask.featureCount, 82);

    final sw = Stopwatch()..start();
    var blocked = 0;
    for (var i = 0; i < 20000; i++) {
      final e = (i % 200) * 12.0 - 1200;
      final n = ((i ~/ 200) % 200) * 12.0 - 1200;
      if (mask.blocks(dirAt(e, n))) blocked++;
    }
    sw.stop();
    expect(blocked, greaterThan(0));
    // Generous — this is a smoke alarm for an accidental O(features) scan,
    // not a benchmark. 20k probes against 82 corridors is microseconds of
    // real work.
    expect(sw.elapsedMilliseconds, lessThan(400));
  });

  test('a rectangle masked as a capsule covers its ends and not its corners',
      () {
    // How ScatterNodes masks a building site: the inscribed capsule along the
    // long axis. 200 x 40 m, running east.
    const long = 200.0, short = 40.0;
    final half = (long - short) / 2;
    final mask = (builder()
          ..addCapsule(pointAt(-half, 0), pointAt(half, 0), short / 2))
        .build(1);

    expect(mask.blocks(dirAt(0, 0)), isTrue, reason: 'the middle');
    expect(mask.blocks(dirAt(95, 0)), isTrue, reason: 'the far end');
    expect(mask.blocks(dirAt(0, 19)), isTrue, reason: 'the near flank');
    expect(mask.blocks(dirAt(0, 30)), isFalse, reason: 'past the flank');
    // The corner of the bounding box is outside the inscribed capsule — the
    // under-mask this shape trades for not clearing trees off the whole
    // half-diagonal.
    expect(mask.blocks(dirAt(99, 19)), isFalse);
  });

  test('the version is what a consumer keys staleness on', () {
    final a = (builder()..addDisc(pointAt(0, 0), 10)).build(7);
    final b = (builder()..addDisc(pointAt(0, 0), 10)).build(9);
    expect(a.version, 7);
    expect(b.version, 9);
    expect(a.version == b.version, isFalse);
  });

  test('the flattening is stable away from the frame origin', () {
    // A site at 45 degrees on a different face of the sphere: the mask has no
    // preferred axis, so the same geometry must behave the same way there.
    final o = Vector3(1, 1, 1).normalized * groundR;
    final up = o.normalized;
    final east = up.cross(const Vector3(0, 0, 1)).normalized;
    final b = ScatterMaskBuilder(originBF: o, groundRadiusM: groundR)
      ..addDisc(o, 50);
    final mask = b.build(1);

    expect(mask.blocks(up), isTrue);
    expect(mask.blocks((o + east * 30).normalized), isTrue);
    expect(mask.blocks((o + east * 120).normalized), isFalse);
    expect(
        mask.blocks(Vector3(math.cos(1.0), math.sin(1.0), 0).normalized),
        isFalse);
  });
}
