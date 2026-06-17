import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/presenters/perspective_camera.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Camera looking along -Y from +Y (azimuth 0, elevation 0), eye 100 m back.
  const cam = PerspectiveCamera(
    azimuth: 0,
    elevation: 0,
    range: 100,
    fovY: 60 * math.pi / 180,
    viewportH: 800,
  );

  test('a point twice as far projects to ~half the on-screen radius', () {
    // Two equal spheres in front of the camera, one at 2x the distance. Apparent
    // size is the true ANGULAR radius tan(asin(R/d)) (so a body at the frame edge
    // doesn't bloat) — exactly 1/2 only in the small-angle limit, hence the loose
    // tolerance rather than 1e-6.
    final near = cam.radiusPx(const Vector3(0, 100, 0), 10); // 200 m from eye
    final far = cam.radiusPx(const Vector3(0, 300, 0), 10); // 400 m from eye
    expect(near, greaterThan(0));
    expect(far / near, closeTo(0.5, 1e-2));
  });

  test('a point behind the eye returns null from projectPx', () {
    // Eye sits at y = -100 (range 100 back along -forward). A point well behind
    // it is culled.
    expect(cam.projectPx(const Vector3(0, -1000, 0)), isNull);
  });

  test('a point in front projects and centres on the view axis', () {
    final p = cam.projectPx(const Vector3(0, 0, 0)); // the target itself
    expect(p, isNotNull);
    // The target is dead ahead -> centre of screen (0, 0).
    expect(p!.x.abs(), lessThan(1e-6));
    expect(p.y.abs(), lessThan(1e-6));
  });

  test('depth grows away from the camera', () {
    final dNear = cam.depth(const Vector3(0, 0, 0));
    final dFar = cam.depth(const Vector3(0, 500, 0));
    expect(dFar, greaterThan(dNear));
  });
}
