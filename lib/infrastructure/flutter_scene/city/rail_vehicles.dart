// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Rolling stock for the ground railway: locomotives, coaches and wagons.
///
/// Built the way [VehicleMeshes] builds cars — boxes in scene units, +Y the
/// direction of travel, +Z up, standing on the rail head — and instanced the
/// same way: the geometry goes to the GPU once per kind and every car after
/// that costs a matrix.
library;

import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';

/// One kind of rail vehicle, with its real-world length.
enum RailCarKind {
  /// A diesel-electric locomotive: long hood, raised cab, short nose.
  loco(lengthM: 20.0, widthM: 3.0, heightM: 4.3),

  /// A passenger coach: a window band the length of the car.
  coach(lengthM: 24.0, widthM: 3.0, heightM: 4.0),

  /// A covered goods wagon.
  boxcar(lengthM: 16.0, widthM: 2.9, heightM: 4.0),

  /// A tank wagon: a barrel on a flat frame.
  tanker(lengthM: 16.0, widthM: 2.8, heightM: 3.9),

  /// A flat wagon carrying two containers.
  flatcar(lengthM: 18.0, widthM: 2.9, heightM: 3.8),

  /// An open hopper.
  hopper(lengthM: 15.0, widthM: 3.0, heightM: 3.7);

  const RailCarKind({
    required this.lengthM,
    required this.widthM,
    required this.heightM,
  });

  final double lengthM;
  final double widthM;
  final double heightM;

  /// Whether a window band lights at night.
  bool get glazed => this == RailCarKind.loco || this == RailCarKind.coach;
}

/// Mesh emitters for [RailCarKind].
class RailVehicleMeshes {
  const RailVehicleMeshes._();

  /// Height of the rail head above the graded corridor, metres — what the
  /// track emitter builds to, and what a car's wheels stand on.
  static const double railHeadM = 0.61;

  /// One vehicle of [kind] at the origin, +Y forward, +Z up, in scene units.
  static void emitModel(MeshBuilder body, MeshBuilder glass, RailCarKind kind) {
    const at = Vector3.zero;
    const along = Vector3.unitY;
    const up = Vector3.unitZ;
    final side = along.cross(up).normalized;
    final w = kind.widthM / 2;
    final half = kind.lengthM / 2;
    // Wheels and frame: the body rides this high above the rail head.
    const frameM = 1.05;

    void box(MeshBuilder m, double from, double to, double halfW, double lo,
        double hi, double uu) {
      final c = <Vector3>[
        at + along * from - side * halfW + up * lo,
        at + along * to - side * halfW + up * lo,
        at + along * to + side * halfW + up * lo,
        at + along * from + side * halfW + up * lo,
        at + along * from - side * halfW + up * hi,
        at + along * to - side * halfW + up * hi,
        at + along * to + side * halfW + up * hi,
        at + along * from + side * halfW + up * hi,
      ];
      // The same face table and winding as VehicleMeshes.emit — measured
      // against geometry known to draw the right way round, not reasoned.
      final n = [up, up * -1, side, side * -1, along, along * -1];
      final faces = [
        [4, 5, 6, 7],
        [3, 2, 1, 0],
        [2, 6, 5, 1],
        [0, 4, 7, 3],
        [1, 5, 4, 0],
        [3, 7, 6, 2],
      ];
      for (var f = 0; f < faces.length; f++) {
        final q = [
          for (final i in faces[f]) m.vertex(c[i] * kRenderScale, n[f], uu, 0.5)
        ];
        m.quad(q[3], q[2], q[1], q[0]);
      }
    }

    // Bogies: a block under each end, the width of the car's frame.
    void bogies() {
      for (final s in const [-1.0, 1.0]) {
        box(body, s * (half - 3.4) - 1.3, s * (half - 3.4) + 1.3, w * 0.8, 0.0,
            frameM * 0.9, 0.35);
      }
    }

    final h = kind.heightM;
    switch (kind) {
      case RailCarKind.loco:
        // Frame the full length, a long hood, and a cab a third of the way
        // back with windows all round; a low short nose in front of it.
        box(body, -half, half, w, frameM * 0.8, frameM + 0.4, 0.5);
        box(body, -half + 0.6, half * 0.25, w * 0.92, frameM + 0.4, h * 0.86,
            0.5);
        box(body, half * 0.25, half * 0.62, w, frameM + 0.4, h * 0.66, 0.5);
        box(glass, half * 0.25, half * 0.62, w * 0.96, h * 0.66, h, 0.5);
        box(body, half * 0.62, half - 0.3, w * 0.9, frameM + 0.4, h * 0.55,
            0.5);
      case RailCarKind.coach:
        box(body, -half, half, w, frameM * 0.8, h * 0.52, 0.5);
        box(glass, -half + 1.2, half - 1.2, w * 0.98, h * 0.52, h * 0.78, 0.5);
        box(body, -half, half, w * 0.97, h * 0.78, h, 0.5);
      case RailCarKind.boxcar:
        box(body, -half, half, w, frameM * 0.8, h, 0.5);
      case RailCarKind.tanker:
        // A barrel is an octagon at this range: the frame, then a slab
        // narrower than the frame with chamfered shoulders faked by a second,
        // narrower slab on top.
        box(body, -half, half, w, frameM * 0.8, frameM + 0.2, 0.5);
        box(body, -half + 1.0, half - 1.0, w * 0.9, frameM + 0.2, h * 0.72,
            0.5);
        box(body, -half + 1.4, half - 1.4, w * 0.62, h * 0.72, h, 0.5);
      case RailCarKind.flatcar:
        box(body, -half, half, w, frameM * 0.8, frameM + 0.3, 0.5);
        // Two 20-foot boxes with a gap between.
        for (final s in const [-1.0, 1.0]) {
          box(body, s * 3.4 - 3.0, s * 3.4 + 3.0, w * 0.86, frameM + 0.3, h,
              0.5);
        }
      case RailCarKind.hopper:
        box(body, -half, half, w, frameM * 0.8, frameM + 0.4, 0.5);
        box(body, -half + 0.5, half - 0.5, w * 0.96, frameM + 0.4, h, 0.5);
    }
    bogies();
  }
}
