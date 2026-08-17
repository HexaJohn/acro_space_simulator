// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/presenters/camera_view.dart';
import 'package:acro_space_simulator/adapters/presenters/surface_picker.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

/// Editing the city from the cockpit needs one thing above all: an answer to
/// "which piece of ground did the player just click on".
void main() {
  const picker = SurfacePicker();
  const radius = 600000.0;

  // Colony at lat 0 / lon 0, so its up is +X and its east/north are +Y/+Z.
  final siteBF = Vector3(radius, 0, 0);

  /// A camera 2 km above the site, looking straight down.
  SceneCamera overhead() => _FakeCamera(
        forward: const Vector3(-1, 0, 0),
        right: const Vector3(0, 1, 0),
        up: const Vector3(0, 0, 1),
        eyeOffset: const Vector3(2000, 0, 0),
      );

  SurfaceHit? pickAt(double x, double y, {SceneCamera? cam}) => picker.pick(
        tapX: x,
        tapY: y,
        viewportW: 800,
        viewportH: 600,
        camera: cam ?? overhead(),
        focusWorld: siteBF,
        bodyWorld: Vector3.zero,
        bodyOrientation: Quaternion.identity,
        groundRadiusM: radius,
        colonyLatDeg: 0,
        colonyLonDeg: 0,
      );

  test('a tap at screen centre lands directly under the camera', () {
    final hit = pickAt(400, 300);
    expect(hit, isNotNull);
    expect(hit!.east, closeTo(0, 0.5));
    expect(hit.north, closeTo(0, 0.5));
    expect(hit.rangeM, closeTo(2000, 1));
    // And on the surface, not through it.
    expect(hit.worldPoint.length, closeTo(radius, 0.5));
  });

  test('screen right is east and screen up is north', () {
    final right = pickAt(500, 300)!;
    final up = pickAt(400, 200)!;
    expect(right.east, greaterThan(50));
    expect(right.north, closeTo(0, 1));
    expect(up.north, greaterThan(50));
    expect(up.east, closeTo(0, 1));
  });

  test('a tap on empty sky hits nothing', () {
    // Looking away from the body entirely.
    final away = _FakeCamera(
      forward: const Vector3(1, 0, 0),
      right: const Vector3(0, -1, 0),
      up: const Vector3(0, 0, 1),
      eyeOffset: const Vector3(2000, 0, 0),
    );
    expect(pickAt(400, 300, cam: away), isNull);
  });

  test('the near surface is picked, never the far side of the planet', () {
    final hit = pickAt(400, 300)!;
    // The visible face is the one nearest the eye: +X here, not -X.
    expect(hit.worldPoint.x, greaterThan(0));
  });

  test('tangent offsets resolve to grid cells, and off-map is nothing', () {
    const grid = 20;
    const cell = 24.0;
    // Dead centre of a 20x20 map is the boundary of cell (10,10).
    expect(picker.cellAt(east: 1, north: 1, grid: grid, cellM: cell),
        10 * grid + 10);
    // One cell west and south.
    expect(picker.cellAt(east: -1, north: -1, grid: grid, cellM: cell),
        9 * grid + 9);
    // Beyond the map edge: nothing, rather than clamping onto the rim.
    expect(picker.cellAt(east: 5000, north: 0, grid: grid, cellM: cell), isNull);
    expect(picker.cellAt(east: 0, north: -5000, grid: grid, cellM: cell), isNull);
  });

  test('a tilted view still lands on the ground it is pointed at', () {
    // Eye 2 km up and 1 km south, looking down-forward at the site.
    final eye = Vector3(radius + 1400, 0, -1000) - siteBF;
    final fwd = (Vector3.zero - eye).normalized;
    final right = const Vector3(0, 1, 0);
    final up = right.cross(fwd).normalized * -1;
    final hit = picker.pick(
      tapX: 400,
      tapY: 300,
      viewportW: 800,
      viewportH: 600,
      camera: _FakeCamera(
          forward: fwd, right: right, up: up, eyeOffset: eye),
      focusWorld: siteBF,
      bodyWorld: Vector3.zero,
      bodyOrientation: Quaternion.identity,
      groundRadiusM: radius,
      colonyLatDeg: 0,
      colonyLonDeg: 0,
    );
    expect(hit, isNotNull);
    expect(hit!.worldPoint.length, closeTo(radius, 1));
    expect(hit.east.abs(), lessThan(50));
    expect(hit.north.abs(), lessThan(50));
  });

  test('a rotated body maps the hit back into its own frame', () {
    // Spin the planet a quarter turn about Z; the same screen tap must come
    // back as the same BODY-FIXED point, since the colony turned with it.
    final spun = Quaternion.axisAngle(Vector3.unitZ, math.pi / 2);
    final hit = picker.pick(
      tapX: 400,
      tapY: 300,
      viewportW: 800,
      viewportH: 600,
      camera: _FakeCamera(
        forward: const Vector3(0, -1, 0),
        right: const Vector3(-1, 0, 0),
        up: const Vector3(0, 0, 1),
        eyeOffset: const Vector3(0, 2000, 0),
      ),
      focusWorld: Vector3(0, radius, 0),
      bodyWorld: Vector3.zero,
      bodyOrientation: spun,
      groundRadiusM: radius,
      colonyLatDeg: 0,
      colonyLonDeg: 0,
    );
    expect(hit, isNotNull);
    expect(hit!.bodyFixed.x, closeTo(radius, 1));
    expect(hit.east.abs(), lessThan(1));
    expect(hit.north.abs(), lessThan(1));
  });
}

class _FakeCamera implements SceneCamera {
  _FakeCamera({
    required this.forward,
    required this.right,
    required this.up,
    required this.eyeOffset,
  });

  @override
  final Vector3 forward;
  @override
  final Vector3 right;
  @override
  final Vector3 up;
  @override
  Vector3 get referenceUp => Vector3.unitZ;
  @override
  final Vector3 eyeOffset;

  @override
  double get azimuth => 0;
  @override
  double get elevation => 0;
  @override
  ({double x, double y})? projectPx(Vector3 rel) => null;
  @override
  double radiusPx(Vector3 rel, double radiusM) => 0;
  @override
  double depth(Vector3 rel) => 0;
  @override
  Vector3 viewDirTo(Vector3 rel) => forward;
  @override
  bool get usesDistanceCull => true;
  @override
  double get nearPlane => 1;
  // 600 px tall viewport at a ~1 rad vertical FOV.
  @override
  double get focalPx => 300 / math.tan(0.5);
  @override
  bool get isTopish => true;
}
