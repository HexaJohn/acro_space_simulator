// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A sealed pedestrian tube running along the verge.
///
/// On an airless world people cannot use a pavement, and the colony already
/// says so for its grid roads — `roadSealed` renders those as pressurised
/// tubes. The spline roads the in-world editor builds never carried the flag,
/// so a lunar street was drawn as open asphalt with a curb nobody could stand
/// on. This is the same idea, cut as real geometry: a hexagonal glass barrel
/// on a low curb, offset clear of the carriageway.
///
/// It lives out here, next to the viaduct and the street furniture, because a
/// barrel is the one piece of city geometry whose winding cannot be checked by
/// looking at it: an inside-out tube still reads as a tube until you notice
/// you are seeing its far wall through its near one. Out of the renderer it is
/// a pure function of a polyline, and a test can measure the winding.
library;

import 'dart:math' as math;

import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';

class PedestrianTube {
  const PedestrianTube._();

  /// Half the span of the barrel, and the height of the walkway inside it.
  static const double radiusM = 1.7;

  /// A hexagon: enough to read as round at street scale, and six quads a ring
  /// is what keeps a whole sealed colony's worth of tube affordable.
  static const int sides = 6;

  /// Build the tube carrying [pts] (anchor-relative metres) into [solid] (the
  /// curb) and [glass] (the barrel).
  static void emit(
    MeshBuilder solid,
    MeshBuilder glass, {
    required List<Vector3> pts,
    required double halfWidthM,
    required Vector3 anchorBF,
  }) {
    List<int>? prev;
    List<int>? prevCurb;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      final up = (p + anchorBF).normalized;
      final ahead = i + 1 < pts.length ? pts[i + 1] - p : p - pts[i - 1];
      if (ahead.length < 1e-6) continue;
      final along = ahead.normalized;
      final side = along.cross(up).normalized;
      // Outside the curb, clear of the traffic lane.
      final axis = p + side * (halfWidthM + radiusM + 1.0) + up * 0.2;

      final ring = <int>[];
      for (var k = 0; k < sides; k++) {
        final a = 2 * math.pi * k / sides + math.pi / sides;
        final n = side * math.cos(a) + up * math.sin(a);
        ring.add(glass.vertex(
            (axis + n * radiusM + up * radiusM) * kRenderScale,
            n,
            k / sides,
            0.5));
      }
      // A curb strip under it, so the barrel does not float on the ground.
      final curb = [
        solid.vertex((axis - side * radiusM) * kRenderScale, up, 0, 0.5),
        solid.vertex((axis + side * radiusM) * kRenderScale, up, 1, 0.5),
      ];
      if (prev != null && prevCurb != null) {
        for (var k = 0; k < sides; k++) {
          final n = (k + 1) % sides;
          // Ring angle runs from `side` towards `up`, which turns about
          // -`along` — the opposite hand to the direction of travel. So the
          // quad has to run BACKWARDS along the tube (this ring, then the one
          // behind it) for its right-hand normal to come out radially outward,
          // which is the order MeshBuilder.quad wants. Sweeping forwards, the
          // obvious way, wound every barrel in the colony inside out.
          glass.quad(ring[k], ring[n], prev[n], prev[k]);
        }
        solid.quad(prevCurb[0], prevCurb[1], curb[1], curb[0]);
      }
      prev = ring;
      prevCurb = curb;
    }
  }
}
