// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Known-size objects, planted in the middle of a colony.
///
/// "Scale looks inconsistent" is hard to act on and easy to argue about,
/// because nothing in a generated city is a size anyone knows by eye — every
/// building is sized from its lot, every lot from a road spacing, and all of
/// it is plausible at any scale. Standing a metre rule next to it turns the
/// question into a measurement: if the mast's bands are a metre and a house is
/// two bands tall, the house is wrong, and it is wrong by a factor you can
/// read off.
///
/// Everything here is a REAL dimension, chosen because it is one people carry
/// in their heads: a person, a car, a storey, a lane.
library;

import 'dart:math' as math;

import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import 'oriented_box.dart';
import 'vehicle_meshes.dart';

class ScaleRig {
  const ScaleRig._();

  /// Height of the banded mast, metres. Tall enough to measure a tower
  /// against, banded finely enough to measure a doorway.
  static const double mastHeightM = 100;

  /// Build the rig at [at], with [up] the local radial and [north] a tangent.
  ///
  /// [solid] takes the structure, [glow] the alternating bands — on the
  /// glazing material they stay readable against any ground and at night.
  static void emit(
    MeshBuilder solid,
    MeshBuilder glow,
    Vector3 at,
    Vector3 north,
    Vector3 up,
  ) {
    final east = north.cross(up).normalized;

    // --- Banded mast ------------------------------------------------------
    // 1 m bands to 10 m — the range a person, a door, a storey live in — then
    // 10 m bands to 100 m for the towers. The change in band size is itself
    // the 10 m mark, so it needs no label.
    var h = 0.0;
    var band = 0;
    while (h < mastHeightM) {
      final step = h < 10 ? 1.0 : 10.0;
      _box(band.isEven ? solid : glow, at + up * (h + step / 2), east, north, up,
          0.35, 0.35, step / 2);
      h += step;
      band++;
    }

    // --- Things whose size everyone knows ---------------------------------
    // A person: 1.8 m. The one measurement nobody has to look up.
    _box(glow, at + east * 3 + up * 0.9, east, north, up, 0.25, 0.18, 0.9);

    // A car, from the real vehicle meshes, so the traffic in the streets can
    // be compared against a known-good copy of itself.
    VehicleMeshes.emit(solid, glow, VehicleKind.sedan, at + east * 6, north, up,
        u: 0.5);

    // A single storey: 3 m, as a flat slab on a post. A building's floor count
    // is readable by eye against it.
    _box(solid, at + east * 11 + up * 1.5, east, north, up, 0.12, 0.12, 1.5);
    _box(glow, at + east * 11 + up * 3.05, east, north, up, 1.2, 1.2, 0.05);

    // A traffic lane: 3.5 m across, laid on the ground. Streets should read as
    // two of these plus curbs. Slabs sit ON the ground, lifted by their own
    // half-thickness — centred on it they sink halfway in and z-fight the
    // terrain they are meant to be measuring.
    _box(glow, at + north * -8 + up * 0.04, east, north, up, 1.75, 6.0, 0.04);

    // A 10 m ruler on the ground, in 1 m bands, running east.
    for (var i = 0; i < 10; i++) {
      _box(i.isEven ? solid : glow,
          at + north * -12 + east * (i + 0.5) + up * 0.03, east, north, up, 0.5,
          0.6, 0.03);
    }
  }

  /// An axis-aligned box in the rig's own frame, [hx]/[hy]/[hz] half-extents.
  static void _box(MeshBuilder m, Vector3 c, Vector3 east, Vector3 north,
          Vector3 up, double hx, double hy, double hz) =>
      OrientedBox.emit(m, c, east, north, up, hx, hy, hz);

  /// Where the rig stands relative to a colony centre, so a caller can frame
  /// it. The mast is at the origin; everything else fans out east and south.
  static double get extentM => math.max(14, 12);
}
