// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/debug_camera_rig.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rig splits the lens the streamers budget against from the camera
/// that renders. Frozen, the probe must stay put over the ground whatever
/// the floating origin and the body do; live, it must be invisible.
void main() {
  const r = 1.7374e6;
  final centre = Vector3(1e9, -2e9, 3e8);
  final eyeWorld = centre + Vector3(r + 5000, 0, 0);
  final fwd = Vector3(-1, 0, 0);
  final up = Vector3.unitZ;

  void close(Vector3 a, Vector3 b, {double tol = 1e-6, String? reason}) {
    expect((a - b).length, lessThan(tol), reason: reason ?? '$a vs $b');
  }

  test('live: the probe is the live lens, untouched', () {
    final rig = DebugCameraRig();
    expect(rig.frozen, isFalse);
    final liveEye = Vector3(10, 20, 30);
    final probe = rig.probe(
        liveEyeRel: liveEye,
        liveForward: Vector3.unitY,
        liveFocalPx: 640,
        focusWorld: centre);
    close(probe.eyeRel, liveEye);
    close(probe.forward, Vector3.unitY);
    expect(probe.focalPx, 640);
  });

  test('frozen: the eye stays put in the world as the origin walks', () {
    final rig = DebugCameraRig();
    rig.freeze(
        eyeWorld: eyeWorld,
        forwardWorld: fwd,
        upWorld: up,
        focalPx: 800,
        fovRadiansY: 0.8,
        aspect: 1.5,
        bodyCentreWorld: centre);
    expect(rig.frozen, isTrue);
    for (final focus in [centre, centre + Vector3(r, 0, 0), eyeWorld]) {
      final probe = rig.probe(
          liveEyeRel: Vector3(1, 2, 3),
          liveForward: Vector3.unitY,
          liveFocalPx: 1,
          focusWorld: focus,
          bodyCentreWorld: centre);
      close(probe.eyeRel, eyeWorld - focus,
          reason: 'the frozen eye must be world-invariant');
      close(probe.forward, fwd);
      expect(probe.focalPx, 800, reason: 'the frozen budget, not the live');
    }
  });

  test('frozen: the pose co-rotates with the body it was frozen over', () {
    final rig = DebugCameraRig();
    rig.freeze(
        eyeWorld: eyeWorld,
        forwardWorld: fwd,
        upWorld: up,
        focalPx: 800,
        fovRadiansY: 0.8,
        aspect: 1.5,
        bodyCentreWorld: centre,
        bodyQuat: Quaternion.identity);
    // A quarter turn about the spin axis: the site under the eye is now on
    // +Y, and the probe must have gone with it.
    final turned = Quaternion.axisAngle(Vector3.unitZ, math.pi / 2);
    final probe = rig.probe(
        liveEyeRel: Vector3.zero,
        liveForward: Vector3.unitY,
        liveFocalPx: 1,
        focusWorld: centre,
        bodyCentreWorld: centre,
        bodyQuat: turned);
    close(probe.eyeRel, Vector3(0, r + 5000, 0), tol: 1e-3);
    close(probe.forward, Vector3(0, -1, 0));
    close(rig.frozenEyeWorld(bodyCentreWorld: centre, bodyQuat: turned),
        centre + Vector3(0, r + 5000, 0),
        tol: 1e-3);
    close(rig.frozenUpWorld(bodyQuat: turned), Vector3.unitZ);
  });

  test('release: back to the live lens', () {
    final rig = DebugCameraRig();
    rig.freeze(
        eyeWorld: eyeWorld,
        forwardWorld: fwd,
        upWorld: up,
        focalPx: 800,
        fovRadiansY: 0.8,
        aspect: 1.5);
    rig.release();
    expect(rig.frozen, isFalse);
    expect(rig.pose, isNull);
    final probe = rig.probe(
        liveEyeRel: Vector3(7, 8, 9),
        liveForward: Vector3.unitX,
        liveFocalPx: 5,
        focusWorld: Vector3.zero);
    close(probe.eyeRel, Vector3(7, 8, 9));
    expect(probe.focalPx, 5);
  });

  test('frustum corners span the field of view at the given distance', () {
    const fov = 0.8;
    const aspect = 2.0;
    const d = 100.0;
    final corners = DebugCameraRig.frustumCorners(
        Vector3.unitX, Vector3.unitZ, fov, aspect, d);
    expect(corners, hasLength(4));
    final halfH = d * math.tan(fov / 2);
    final halfW = halfH * aspect;
    for (final c in corners) {
      expect(c.x, closeTo(d, 1e-9), reason: 'all on the plane at d');
      expect(c.z.abs(), closeTo(halfH, 1e-9), reason: 'up extent');
      expect(c.y.abs(), closeTo(halfW, 1e-9), reason: 'right extent');
    }
    // Top-left, top-right, bottom-right, bottom-left: tops share +up.
    expect(corners[0].z, greaterThan(0));
    expect(corners[1].z, greaterThan(0));
    expect(corners[2].z, lessThan(0));
    expect(corners[3].z, lessThan(0));
    expect(corners[0].y, isNot(closeTo(corners[1].y, 1e-9)));
  });

  test('frustum corners tolerate an up that is not orthogonal to forward', () {
    // The orbit camera's up is the site radial, which the view direction
    // usually leans into; the rectangle must still be square to forward.
    final f = Vector3(1, 0, -0.5).normalized;
    final corners =
        DebugCameraRig.frustumCorners(f, Vector3.unitZ, 0.8, 1.0, 50);
    for (final c in corners) {
      expect(c.dot(f), closeTo(50, 1e-9));
    }
  });
}
