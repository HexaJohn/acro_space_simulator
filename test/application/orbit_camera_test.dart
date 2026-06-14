import 'dart:math' as math;

import 'package:acro_space_simulator/application/view/orbit_camera.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  OrbitCamera camera() => const OrbitCamera(
        focus: Vector3.zero,
        distance: 100,
        yaw: 0,
        pitch: 0,
      );

  test('orbiting changes eye position but keeps distance to focus constant', () {
    final c = camera();
    final eye0 = c.eyePosition();
    final c2 = c.orbit(deltaYaw: 0.5, deltaPitch: 0.3);
    final eye1 = c2.eyePosition();

    expect(eye0.distanceTo(eye1), greaterThan(1e-3)); // moved
    expect(eye0.distanceTo(c.focus), closeTo(100, 1e-6));
    expect(eye1.distanceTo(c2.focus), closeTo(100, 1e-6)); // radius unchanged
  });

  test('zoom changes distance within clamps', () {
    final c = camera();
    final zoomedIn = c.zoom(0.5); // scale distance by 0.5
    expect(zoomedIn.distance, closeTo(50, 1e-6));

    // Clamp at the minimum: huge zoom-in does not go below minDistance.
    final tiny = c.zoom(1e-9);
    expect(tiny.distance, greaterThanOrEqualTo(tiny.minDistance));
    expect(tiny.distance, closeTo(tiny.minDistance, 1e-6));

    // Clamp at the maximum: huge zoom-out does not exceed maxDistance.
    final huge = c.zoom(1e9);
    expect(huge.distance, lessThanOrEqualTo(huge.maxDistance));
    expect(huge.distance, closeTo(huge.maxDistance, 1e-6));
  });

  test('pitch clamps to avoid flipping over the poles', () {
    final c = camera();
    final up = c.orbit(deltaYaw: 0, deltaPitch: 100); // way past vertical
    expect(up.pitch, lessThan(math.pi / 2));
    expect(up.pitch, greaterThan(0));

    final down = c.orbit(deltaYaw: 0, deltaPitch: -100);
    expect(down.pitch, greaterThan(-math.pi / 2));
    expect(down.pitch, lessThan(0));
  });

  test('eyePosition and forward are consistent (forward points eye -> focus)',
      () {
    final c = const OrbitCamera(
      focus: Vector3(10, 20, 30),
      distance: 75,
      yaw: 0.7,
      pitch: 0.4,
    );
    final eye = c.eyePosition();
    final fwd = c.forward();

    // forward is a unit vector.
    expect(fwd.length, closeTo(1.0, 1e-9));
    // forward points from the eye toward the focus.
    final toFocus = (c.focus - eye).normalized;
    expect(fwd.dot(toFocus), closeTo(1.0, 1e-9));
    // Stepping `distance` along forward from the eye lands on the focus.
    final landed = eye + fwd * c.distance;
    expect(landed.distanceTo(c.focus), closeTo(0.0, 1e-6));
  });

  test('panning the focus shifts the eye by the same amount', () {
    final c = camera();
    final eye0 = c.eyePosition();
    final c2 = c.pan(const Vector3(5, -3, 2));
    final eye1 = c2.eyePosition();
    expect((eye1 - eye0), equals(const Vector3(5, -3, 2)));
    expect(c2.focus, equals(const Vector3(5, -3, 2)));
  });

  test('OrbitCamera is an immutable value object with equality', () {
    const a = OrbitCamera(
        focus: Vector3.zero, distance: 100, yaw: 0.1, pitch: 0.2);
    const b = OrbitCamera(
        focus: Vector3.zero, distance: 100, yaw: 0.1, pitch: 0.2);
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
  });
}
