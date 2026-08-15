// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Turning a tap on the 3D view into a point on a colony's ground.
///
/// This is what makes the flight view editable: without it the only way to
/// place a building is a top-down 2D map, because nothing can answer "which
/// piece of land did the player just click on".
///
/// Pure geometry, no Flutter — the ray maths is the part worth testing, and
/// it is identical whether the tap came from a mouse, a touch, or a test.
library;

import 'dart:math' as math;

import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import 'camera_view.dart';

/// Where a screen ray met the ground.
class SurfaceHit {
  const SurfaceHit({
    required this.worldPoint,
    required this.bodyFixed,
    required this.east,
    required this.north,
    required this.rangeM,
  });

  /// Hit point in world metres.
  final Vector3 worldPoint;

  /// The same point in the body's rotating frame.
  final Vector3 bodyFixed;

  /// Offset from the colony site along the local tangent, metres. These are
  /// the coordinates parcels and grid cells are expressed in.
  final double east, north;

  /// Distance from the eye, metres.
  final double rangeM;
}

class SurfacePicker {
  const SurfacePicker();

  /// The ground point under a tap.
  ///
  /// [tapX]/[tapY] are viewport pixels from the top-left. [focusWorld] is the
  /// floating origin's focus, since the camera reports its eye RELATIVE to it.
  /// [groundRadiusM] should be the radius the terrain actually sits at under
  /// the colony — passing the datum radius on a body with relief puts the hit
  /// point underground on a hill and above it in a valley.
  SurfaceHit? pick({
    required double tapX,
    required double tapY,
    required double viewportW,
    required double viewportH,
    required SceneCamera camera,
    required Vector3 focusWorld,
    required Vector3 bodyWorld,
    required Quaternion bodyOrientation,
    required double groundRadiusM,
    required double colonyLatDeg,
    required double colonyLonDeg,
  }) {
    if (viewportW <= 0 || viewportH <= 0) return null;

    // Screen -> camera ray, using the camera's OWN focal length rather than one
    // re-derived from a field of view here. Re-deriving it is how a picker
    // drifts from the projection it is picking against — the two would have to
    // be kept in step by hand forever, and an ortho camera has no usable FOV
    // at all.
    final focalPx = camera.focalPx;
    final sx = tapX - viewportW / 2;
    final sy = viewportH / 2 - tapY; // screen Y grows downward
    final dir = (camera.forward * focalPx + camera.right * sx + camera.up * sy)
        .normalized;

    // Eye in world space.
    final eye = focusWorld + camera.eyeOffset;

    // Ray/sphere against the body's ground.
    final oc = eye - bodyWorld;
    final b = 2 * oc.dot(dir);
    final c = oc.dot(oc) - groundRadiusM * groundRadiusM;
    final disc = b * b - 4 * c;
    if (disc < 0) return null; // the ray misses the body entirely
    final root = math.sqrt(disc);
    // Near root first: the visible surface is the front of the sphere. Taking
    // the far one would let a click pass through the planet and land on the
    // ground behind it.
    var t = (-b - root) / 2;
    if (t < 0) t = (-b + root) / 2;
    if (t < 0) return null; // the body is behind the camera

    final world = eye + dir * t;
    final bodyFixed = bodyOrientation.conjugate.rotate(world - bodyWorld);

    // Body-fixed -> colony tangent frame. The colony's east/north axes are
    // perpendicular to its up, so the offsets are just projections onto them
    // — the exact inverse of how SurfacePlacement builds a position.
    final lat = colonyLatDeg * math.pi / 180;
    final lon = colonyLonDeg * math.pi / 180;
    final cl = math.cos(lat), sl = math.sin(lat);
    final co = math.cos(lon), so = math.sin(lon);
    final up = Vector3(cl * co, cl * so, sl);
    final east = Vector3(-so, co, 0);
    final north = up.cross(east);

    return SurfaceHit(
      worldPoint: world,
      bodyFixed: bodyFixed,
      east: bodyFixed.dot(east),
      north: bodyFixed.dot(north),
      rangeM: t,
    );
  }

  /// The grid cell containing a tangent offset, for a colony of [grid] cells a
  /// side at [cellM] metres each, centred on the colony site.
  ///
  /// Returns null outside the map rather than clamping: a click on the horizon
  /// should do nothing, not build on the map's edge.
  int? cellAt({
    required double east,
    required double north,
    required int grid,
    required double cellM,
  }) {
    final half = grid / 2.0;
    final gx = (east / cellM + half).floor();
    final gy = (north / cellM + half).floor();
    if (gx < 0 || gy < 0 || gx >= grid || gy >= grid) return null;
    return gy * grid + gx;
  }
}
