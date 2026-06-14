import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/vessel/propulsion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a non-gimballed engine thrusts straight along the commanded axis', () {
    const engine = Engine(
      name: 'fixed',
      maxThrustVacuum: 1000,
      maxThrustSeaLevel: 800,
      ispVacuum: 300,
      ispSeaLevel: 250,
      gimbalRange: 0,
    );
    final dir = engine.gimballedDirection(
      thrustAxis: Vector3.unitZ,
      steerToward: Vector3.unitX, // wants to point sideways
    );
    expect(dir.dot(Vector3.unitZ), closeTo(1.0, 1e-9)); // unchanged
  });

  test('a gimballed engine deflects thrust toward the steering direction', () {
    const engine = Engine(
      name: 'vector',
      maxThrustVacuum: 1000,
      maxThrustSeaLevel: 800,
      ispVacuum: 300,
      ispSeaLevel: 250,
      gimbalRange: 0.1, // ~5.7 deg
    );
    final dir = engine.gimballedDirection(
      thrustAxis: Vector3.unitZ,
      steerToward: Vector3.unitX,
    );
    // Deflected toward +X but capped at the gimbal range.
    expect(dir.x, greaterThan(0));
    final angle = math.acos(dir.dot(Vector3.unitZ).clamp(-1.0, 1.0));
    expect(angle, closeTo(0.1, 1e-3));
    expect(dir.length, closeTo(1.0, 1e-9));
  });

  test('gimbal deflection never exceeds the gimbal range', () {
    const engine = Engine(
      name: 'vector',
      maxThrustVacuum: 1000,
      maxThrustSeaLevel: 800,
      ispVacuum: 300,
      ispSeaLevel: 250,
      gimbalRange: 0.05,
    );
    // Steer fully opposite — deflection should still cap at 0.05 rad.
    final dir = engine.gimballedDirection(
      thrustAxis: Vector3.unitZ,
      steerToward: const Vector3(0, 1, 0),
    );
    final angle = math.acos(dir.dot(Vector3.unitZ).clamp(-1.0, 1.0));
    expect(angle, lessThanOrEqualTo(0.05 + 1e-6));
  });
}
