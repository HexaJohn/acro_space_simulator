// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Placeholder road vehicles, built from boxes.
///
/// Deliberately crude: these exist so a colony's streets read as inhabited
/// rather than as empty pavement, and the shape that matters at cockpit range
/// is the silhouette — how long it is, how tall, how many wheels. Detail here
/// would be detail nobody sees, on geometry that is rebuilt every frame.
///
/// Two families, chosen by the world rather than by taste. Where the air is
/// breathable people drive CARS; where it is not, nothing with a cabin vent
/// and rubber tyres would last, so traffic is six-wheeled pressurised ROVERS —
/// the same rule that decides whether a road gets a pavement or a sealed
/// pedestrian tube.
library;

import 'dart:math' as math;

import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';

enum VehicleKind {
  /// Two-box car, short. The commuter of a breathable world.
  coupe(lengthM: 4.2, widthM: 1.8, heightM: 1.30, axles: 2),
  sedan(lengthM: 4.9, widthM: 1.85, heightM: 1.45, axles: 2),

  /// Rigid box truck: a taller body over the same two axles.
  truck(lengthM: 7.0, widthM: 2.25, heightM: 2.70, axles: 2),

  /// Tractor plus trailer, articulated in look if not in behaviour.
  semi(lengthM: 15.5, widthM: 2.5, heightM: 3.60, axles: 3),

  /// Six-wheeled pressurised rover: the only thing that drives on a world with
  /// no air.
  rover(lengthM: 5.4, widthM: 2.45, heightM: 1.95, axles: 3);

  const VehicleKind({
    required this.lengthM,
    required this.widthM,
    required this.heightM,
    required this.axles,
  });

  final double lengthM;
  final double widthM;
  final double heightM;
  final int axles;

  /// The families, in the order a deterministic pick indexes them.
  static const List<VehicleKind> road = [coupe, sedan, truck, semi];
  static const List<VehicleKind> airless = [rover];
}

class VehicleMeshes {
  const VehicleMeshes._();

  /// One vehicle of [kind] in MODEL space: origin on the ground under its
  /// centre, +Y forward, +Z up.
  ///
  /// The instancing form. Built once per kind and drawn with a per-instance
  /// matrix, instead of re-baking every vehicle's geometry into a fresh mesh
  /// each frame — which is what the traffic pass used to do, and what made a
  /// couple of hundred cars cost more than the city they drove through.
  static void emitModel(MeshBuilder body, MeshBuilder glass, VehicleKind kind) =>
      emit(body, glass, kind, Vector3.zero, Vector3.unitY, Vector3.unitZ,
          u: 0.5);

  /// Emit one vehicle of [kind] standing on the ground at [at], pointing
  /// [along], with [up] the local radial.
  ///
  /// Coordinates are built directly in the caller's frame rather than authored
  /// in a model space and transformed: a road curves over a planet, so every
  /// vehicle has its own up, and a shared model matrix would tilt them.
  static void emit(
    MeshBuilder body,
    MeshBuilder glass,
    VehicleKind kind,
    Vector3 at,
    Vector3 along,
    Vector3 up, {
    required double u,
  }) {
    final side = along.cross(up).normalized;
    final w = kind.widthM / 2;
    const wheelR = 0.42;

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
      // Wound to OPPOSE the declared normal, which is this engine's
      // convention — measured against the building geometry, which renders
      // correctly and whose every triangle winds against its own normal.
      //
      // I had this backwards twice. Reasoning from `MeshBuilder.triangle`
      // reversing its arguments gives the wrong answer on its own, because the
      // scene's world-to-scene mapping is itself a mirror (see the chirality
      // note in coord_convert) and the finished image is flipped back. The
      // only reliable check is to compare against geometry known to draw the
      // right way round.
      final n = [up, up * -1, side, side * -1, along, along * -1];
      final faces = [
        [4, 5, 6, 7], // top      (+up)
        [3, 2, 1, 0], // bottom   (-up)
        [2, 6, 5, 1], // +side
        [0, 4, 7, 3], // -side
        [1, 5, 4, 0], // front    (+along, the direction of travel)
        [3, 7, 6, 2], // back
      ];
      for (var f = 0; f < faces.length; f++) {
        final q = [
          for (final i in faces[f]) m.vertex(c[i] * kRenderScale, n[f], uu, 0.5)
        ];
        m.quad(q[3], q[2], q[1], q[0]);
      }
    }

    final half = kind.lengthM / 2;
    switch (kind) {
      case VehicleKind.coupe:
      case VehicleKind.sedan:
        // Lower body the full length, cabin set back and inset — the two-box
        // silhouette that reads as "car" at any distance.
        box(body, -half, half, w, wheelR * 0.6, kind.heightM * 0.62, u);
        box(glass, -half * 0.35, half * 0.45, w * 0.88,
            kind.heightM * 0.62, kind.heightM, u);
      case VehicleKind.truck:
        // Cab at the FRONT (+along is the direction of travel), box behind it.
        // These were built back to front: every truck and semi in the colony
        // drove down the street trailer-first.
        box(body, half * 0.45, half, w, wheelR * 0.6, kind.heightM * 0.62, u);
        box(glass, half * 0.52, half * 0.92, w * 0.9,
            kind.heightM * 0.62, kind.heightM * 0.86, u);
        box(body, -half, half * 0.4, w, wheelR * 0.6, kind.heightM, u);
      case VehicleKind.semi:
        // Tractor at the front, then the trailer trailing BEHIND it.
        box(body, half * 0.72, half, w, wheelR * 0.7, kind.heightM * 0.55, u);
        box(glass, half * 0.76, half * 0.97, w * 0.9,
            kind.heightM * 0.55, kind.heightM * 0.82, u);
        box(body, -half, half * 0.62, w, kind.heightM * 0.42, kind.heightM, u);
      case VehicleKind.rover:
        // A low hull with a cut-back nose and a small pressurised cabin: no
        // bonnet, because there is no engine to put under one.
        box(body, -half, half * 0.86, w, wheelR * 0.8, kind.heightM * 0.55, u);
        box(glass, -half * 0.30, half * 0.42, w * 0.78,
            kind.heightM * 0.55, kind.heightM, u);
    }

    // Wheels: short boxes standing proud of the hull. Round enough at range,
    // and a cylinder each would triple the vehicle's triangle count.
    for (var a = 0; a < kind.axles; a++) {
      final t = kind.axles == 1
          ? 0.0
          : a / (kind.axles - 1) * 2 - 1; // -1 .. 1
      // Axles bunch toward the ends on a car and spread evenly on a rover.
      final at0 = half * (kind == VehicleKind.rover ? t * 0.82 : t * 0.72);
      for (final s in const [1.0, -1.0]) {
        final c = at + along * at0 + side * (w * s * 0.94) + up * wheelR;
        final n = side * s;
        var quadV = <Vector3>[
          c - along * wheelR - up * wheelR,
          c + along * wheelR - up * wheelR,
          c + along * wheelR + up * wheelR,
          c - along * wheelR + up * wheelR,
        ];
        // The two sides face OPPOSITE ways, so they cannot share a winding:
        // emitting both in the same order left one side of every vehicle wound
        // against its own normal, and backface culling then showed the inside
        // of it. Worst on a semi, which carries six wheels to a coupe's four.
        if (s < 0) quadV = quadV.reversed.toList();
        final q = [
          for (final v in quadV)
            body.vertex(v * kRenderScale, n, math.min(u + 0.02, 0.999), 0.5)
        ];
        body.quad(q[0], q[1], q[2], q[3]);
      }
    }
  }
}
