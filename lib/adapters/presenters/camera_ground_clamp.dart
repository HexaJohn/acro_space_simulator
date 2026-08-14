// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../../domain/shared/vector3.dart';
import '../../domain/simulation/epoch.dart';
import '../../domain/terrain/terrain_edits.dart';
import '../../domain/universe/celestial_body.dart';
import 'perspective_camera.dart';

/// Minimum eye height above the local terrain, metres — roughly standing
/// height. Low enough to lie in the dirt next to a lander, high enough that
/// the range-tracking near plane (range/20, capped at 1 m) can never reach
/// through it into the ground.
const double cameraGroundClearance = 2.0;

/// Keep a perspective camera's EYE above [body]'s terrain.
///
/// Orbiting a landed craft (or zooming a body focus down over a mountain) can
/// drag the eye below the surface, where the near plane slices the terrain
/// shell open and the frame fills with the planet's insides. When the eye dips
/// under ground + [clearance] it is pushed RADIALLY out to that floor and the
/// orbit re-derived to look at the same focus from there.
///
/// A TRANSIENT clamp, not a mutation: the caller's stored view state is
/// untouched, so the camera settles back to exactly the user's pose the moment
/// its radial clears the terrain again. Samples the same terrain field (plus
/// crater [edits]) the tick's touchdown uses, so the camera floor IS the
/// ground a craft lands on.
///
/// [focusRelBody] is the camera focus in body-centred INERTIAL metres — zero
/// for a body lock (the focus is the centre), the craft's state vector for a
/// vessel lock. Returns [cam] unchanged whenever the eye is already clear, or
/// the geometry degenerates.
PerspectiveCamera clampPerspectiveEyeAboveTerrain(
  PerspectiveCamera cam, {
  required CelestialBody body,
  required Vector3 focusRelBody,
  required Epoch epoch,
  TerrainEdits? edits,
  double clearance = cameraGroundClearance,
}) {
  final eyeRelBody = focusRelBody + cam.eyeOffset;
  final dist = eyeRelBody.length;
  if (!dist.isFinite || dist <= 0) return cam;

  // Quick reject well above any possible relief: skip the terrain sample for
  // every frame the camera spends in orbit. Crater edits only DIG (and rim
  // lips are small next to the field amplitude), so the ceiling holds.
  final relief = body.terrainField?.amplitude ?? 0.0;
  if (dist > body.radius + relief + clearance) return cam;

  final ground = body.terrainGroundRadius(eyeRelBody, epoch, edits: edits);
  final minR = ground + clearance;
  if (dist >= minR) return cam;

  // Push the eye out to the floor, keep looking at the focus: solve the
  // azimuth/elevation/range that put the eye exactly there. forward is the
  // eye→focus direction (eyeRel = −forward·range), unrotated into the gimbal
  // frame the orbit angles live in.
  final newEyeRel = eyeRelBody.normalized * minR - focusRelBody;
  final newRange = newEyeRel.length;
  if (newRange < 1e-6 || !newRange.isFinite) return cam;
  final fLocal = cam.frame.conjugate.rotate(newEyeRel * (-1 / newRange));
  final elevation = math
      .asin((-fLocal.z).clamp(-1.0, 1.0))
      .clamp(-math.pi / 2 + 0.02, math.pi / 2 - 0.02);
  final azimuth = math.atan2(fLocal.x, fLocal.y);
  return PerspectiveCamera(
    azimuth: azimuth,
    elevation: elevation,
    roll: cam.roll,
    frame: cam.frame,
    range: newRange,
    near: cam.near,
    fovY: cam.fovY,
    viewportH: cam.viewportH,
  );
}
