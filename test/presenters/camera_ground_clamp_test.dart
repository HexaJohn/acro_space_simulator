// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/presenters/camera_ground_clamp.dart';
import 'package:acro_space_simulator/adapters/presenters/perspective_camera.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

/// Cover for "the camera clips into the ground": orbiting a landed craft (or
/// zooming a body lock down over a mountain) used to drag the perspective eye
/// below the terrain, where the near plane slices the shell open and the frame
/// fills with the planet's insides.
///
/// What is pinned here is the transient clamp itself, on the REAL Earth/Moon
/// terrain fields (the same ones the tick's touchdown samples):
///   * an eye already above the ground passes through IDENTICAL — the clamp
///     must never perturb a frame it has no business in;
///   * an eye below the ground comes back at ground + clearance along its own
///     radial, and the rebuilt orbit still has its eye exactly there (the
///     azimuth/elevation/range round trip is what the painter consumes);
///   * the same holds inside a non-identity gimbal frame (the AXIS/GRAVITY
///     up-modes), where the orbit angles live in a rotated basis.
void main() {
  registerBakedDemsForTest();
  final system = RealSolarSystem.build();
  const epoch = Epoch.zero;

  /// A camera whose eye sits at [eyeRel] (metres, relative to the FOCUS): the
  /// inverse of the orbit model, eyeRel = −forward·range. World-frame
  /// azimuth/elevation are NOT local-vertical angles away from the poles, so
  /// tests build cameras from the eye they mean rather than hand-picked
  /// angles. Each call self-checks the round trip, so a camera-model change
  /// fails loudly here instead of silently invalidating the scenario.
  PerspectiveCamera camWithEye(Vector3 eyeRel,
      {Quaternion frame = Quaternion.identity}) {
    final r = eyeRel.length;
    final fLocal = frame.conjugate.rotate(eyeRel * (-1 / r));
    final cam = PerspectiveCamera(
      azimuth: math.atan2(fLocal.x, fLocal.y),
      elevation: math.asin((-fLocal.z).clamp(-1.0, 1.0)),
      range: r,
      frame: frame,
      viewportH: 800,
    );
    expect((cam.eyeOffset - eyeRel).length, lessThan(1e-6 * r + 1e-6),
        reason: 'camWithEye must reproduce the requested eye');
    return cam;
  }

  /// The eye the returned camera actually renders from, in body-centred
  /// inertial metres — focus + the orbit's eye offset.
  Vector3 eyeOf(PerspectiveCamera cam, Vector3 focusRelBody) =>
      focusRelBody + cam.eyeOffset;

  // A mid-latitude surface direction and a horizontal tangent there, shared by
  // the underground scenarios (low |z| keeps every derived elevation far from
  // the ±π/2 pole clamp).
  final dir = Vector3(0.6, -0.48, 0.2).normalized;
  final tangent = Vector3.unitZ.cross(dir).normalized;

  test('an eye already above the terrain is untouched (identical object)', () {
    final earth = system.require(const BodyId('earth'));
    // Landed-craft focus; the eye hangs 400 m radially above it.
    final focus = dir * earth.terrainGroundRadius(dir, epoch);
    final cam = camWithEye(dir * 400);
    final clamped = clampPerspectiveEyeAboveTerrain(cam,
        body: earth, focusRelBody: focus, epoch: epoch);
    expect(identical(clamped, cam), isTrue);
  });

  test('an orbit in space never pays for a terrain sample detour', () {
    final earth = system.require(const BodyId('earth'));
    final focus = Vector3.unitX * (earth.radius + 400000); // LEO craft
    final cam = PerspectiveCamera(range: 600);
    final clamped = clampPerspectiveEyeAboveTerrain(cam,
        body: earth, focusRelBody: focus, epoch: epoch);
    expect(identical(clamped, cam), isTrue);
  });

  test('an eye below the terrain is lifted to ground + clearance', () {
    final earth = system.require(const BodyId('earth'));
    final focus = dir * earth.terrainGroundRadius(dir, epoch);
    // The orbit has swung the eye 100 m INTO the hill, 60 m off to the side —
    // the pose a drag below the horizon of a landed craft produces.
    final cam = camWithEye(dir * -100 + tangent * 60);
    expect(eyeOf(cam, focus).length,
        lessThan(earth.terrainGroundRadius(eyeOf(cam, focus), epoch)),
        reason: 'the scenario must actually start underground');

    final clamped = clampPerspectiveEyeAboveTerrain(cam,
        body: earth, focusRelBody: focus, epoch: epoch);
    final eye = eyeOf(clamped, focus);
    final ground = earth.terrainGroundRadius(eye, epoch);
    // On the floor: at clearance above the ground under the CLAMPED eye. The
    // radial push keeps the eye's own direction, so the sample agrees with the
    // one the clamp made (millimetre slack for the renormalisation round trip).
    expect(eye.length, closeTo(ground + cameraGroundClearance, 1e-3));
    // Still an orbit around the same focus: the rebuilt range IS the
    // eye–focus distance.
    expect(clamped.range, closeTo((eye - focus).length, 1e-6));
    // And the view still points at the focus (forward = eye→focus).
    expect(clamped.forward.dot((focus - eye).normalized), closeTo(1.0, 1e-9));
  });

  test('the clamp survives a non-identity gimbal frame (AXIS/GRAVITY modes)',
      () {
    final earth = system.require(const BodyId('earth'));
    final focus = dir * earth.terrainGroundRadius(dir, epoch);
    final frame = Quaternion.axisAngle(Vector3.unitX, 0.4093); // ~Earth tilt
    final cam = camWithEye(dir * -100 + tangent * 60, frame: frame);

    final clamped = clampPerspectiveEyeAboveTerrain(cam,
        body: earth, focusRelBody: focus, epoch: epoch);
    final eye = eyeOf(clamped, focus);
    expect(eye.length,
        closeTo(earth.terrainGroundRadius(eye, epoch) + cameraGroundClearance,
            1e-3));
    expect(clamped.frame, frame); // the gimbal itself is never rewritten
    expect(clamped.forward.dot((focus - eye).normalized), closeTo(1.0, 1e-9));
  });

  test('a body-lock zoom over lunar terrain stops at the ground', () {
    final moon = system.require(const BodyId('moon'));
    // Body lock: the focus IS the centre and range is measured from it. Park
    // the eye 1 km under the surface along a fixed radial.
    final ground = moon.terrainGroundRadius(dir * moon.radius, epoch);
    final cam = camWithEye(dir * (ground - 1000));

    final clamped = clampPerspectiveEyeAboveTerrain(cam,
        body: moon, focusRelBody: Vector3.zero, epoch: epoch);
    final eye = eyeOf(clamped, Vector3.zero);
    expect(
        eye.length,
        closeTo(moon.terrainGroundRadius(eye, epoch) + cameraGroundClearance,
            1e-3));
    // Still looking at the body centre from that radial.
    expect(clamped.forward.dot((-eye).normalized), closeTo(1.0, 1e-9));
  });
}
