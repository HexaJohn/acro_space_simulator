// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What stands on a lot BESIDES the building: fences, and the signs that make
/// a shop read as a shop.
///
/// A colony where every plot is a box on bare ground reads as a model, not a
/// place. What tells you which is which at street level is the boundary
/// treatment — a picket fence around a house, chain link around a works, a lit
/// sign over a shopfront — and each of those is a property of what the lot is
/// ZONED, which the frame already carries in the building's type.
///
/// Derived on the client from the building itself, the way street lamps and
/// junctions already are: the rule is deterministic and a thousand fence posts
/// per colony is a lot of wire for something both ends can compute.
library;

import 'dart:math' as math;

import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'vehicle_meshes.dart';

/// What a lot's boundary is dressed with.
enum LotEdging {
  /// Painted timber pickets. Low and medium density housing.
  picket,

  /// Chain link on steel posts. Medium and heavy industry.
  chainLink,

  /// Nothing — towers meet the pavement, and a works too small to fence.
  none,
}

class LotFeatures {
  const LotFeatures._();

  /// The edging a lot of this zone type takes.
  ///
  /// Density decides as much as kind does: a house has a garden to enclose and
  /// a tower does not, a heavy works has something worth fencing and a
  /// two-person workshop does not.
  static LotEdging edgingFor(String type) => switch (type) {
        'r-low' || 'r-med' => LotEdging.picket,
        'i-med' || 'i-high' => LotEdging.chainLink,
        _ => LotEdging.none,
      };

  /// Whether this lot carries a lit sign. Commercial, at every density — a
  /// corner shop has a sign as surely as a mall does.
  static bool signFor(String type) =>
      type == 'c-low' || type == 'c-med' || type == 'c-high';

  /// Fence the rectangle [halfW] x [halfD] about [centre].
  ///
  /// [along] is the lot's depth axis and [up] its local radial. Posts and rails
  /// are boxes; at street range the silhouette and the spacing are what read,
  /// and a modelled picket would be a hundred triangles nobody resolves.
  static void emitFence(
    MeshBuilder m,
    LotEdging kind,
    Vector3 centre,
    Vector3 along,
    Vector3 up,
    double halfW,
    double halfD,
  ) {
    if (kind == LotEdging.none) return;
    final side = along.cross(up).normalized;
    final picket = kind == LotEdging.picket;
    final height = picket ? 1.05 : 2.4;
    final spacing = picket ? 0.16 : 2.6;
    final postR = picket ? 0.035 : 0.05;

    // Walk the four edges. The street edge (front) is left OPEN so the lot has
    // a way in — a fully enclosed plot reads as a compound.
    final corners = <(Vector3, Vector3)>[
      (centre - side * halfW - along * halfD,
          centre - side * halfW + along * halfD),
      (centre + side * halfW - along * halfD,
          centre + side * halfW + along * halfD),
      (centre - side * halfW + along * halfD,
          centre + side * halfW + along * halfD),
    ];

    for (final (a, b) in corners) {
      final run = b - a;
      final len = run.length;
      if (len < 0.5) continue;
      final dir = run * (1 / len);
      final n = dir.cross(up).normalized;

      // Uprights.
      final count = math.max(2, (len / spacing).floor());
      for (var i = 0; i <= count; i++) {
        final p = a + dir * (len * i / count);
        _post(m, p, up, dir, n, postR, height);
      }
      // Rails: a picket has two, chain link a top rail only.
      for (final h in picket ? const [0.35, 0.92] : const [0.98]) {
        _rail(m, a, b, up, n, height * h, picket ? 0.03 : 0.04);
      }
      // Chain link reads as a MESH panel: one thin translucent-ish slab per
      // run, which at any distance a fence is seen from is what the wire does.
      if (!picket) {
        _panel(m, a, b, up, n, height);
      }
    }
  }

  /// A lit sign standing at the front of a commercial lot.
  ///
  /// Two pieces: a dark box on a post ([solid]) and the face ([glow]), which
  /// goes on the glazing material so it lights at night the way the windows
  /// already do.
  static void emitSign(
    MeshBuilder solid,
    MeshBuilder glow,
    Vector3 centre,
    Vector3 along,
    Vector3 up,
    double halfW,
    double halfD,
    double scale,
  ) {
    final side = along.cross(up).normalized;
    // At the street edge, offset to one side so it never sits in a doorway.
    final base = centre - along * (halfD * 0.92) + side * (halfW * 0.55);
    final postH = (2.4 * scale).clamp(2.0, 7.0);
    final boardW = (1.9 * scale).clamp(1.2, 5.0);
    final boardH = (0.85 * scale).clamp(0.6, 2.4);

    _post(solid, base, up, along, side, 0.07, postH);
    final face = base + up * (postH + boardH / 2);
    // Board back, then the lit face a hair in front of it so the two never
    // z-fight for the same pixels.
    _board(solid, face, side, up, boardW / 2, boardH / 2, along * -0.03);
    _board(glow, face, side, up, boardW / 2 * 0.92, boardH / 2 * 0.86,
        along * 0.03);
  }

  static void _post(MeshBuilder m, Vector3 base, Vector3 up, Vector3 along,
      Vector3 side, double r, double h) {
    final c = [
      base - side * r - along * r,
      base + side * r - along * r,
      base + side * r + along * r,
      base - side * r + along * r,
    ];
    final top = [for (final v in c) v + up * h];
    for (var i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      final n = (c[i] + c[j]) * 0.5 - base;
      final nn = n.length < 1e-6 ? up : n.normalized;
      final q = [
        m.vertex(c[i] * kRenderScale, nn, 0, 1),
        m.vertex(c[j] * kRenderScale, nn, 1, 1),
        m.vertex(top[j] * kRenderScale, nn, 1, 0),
        m.vertex(top[i] * kRenderScale, nn, 0, 0),
      ];
      m.quad(q[0], q[1], q[2], q[3]);
    }
  }

  static void _rail(MeshBuilder m, Vector3 a, Vector3 b, Vector3 up, Vector3 n,
      double h, double t) {
    final lo = h - t, hi = h + t;
    final q = [
      m.vertex((a + up * lo) * kRenderScale, n, 0, 1),
      m.vertex((b + up * lo) * kRenderScale, n, 1, 1),
      m.vertex((b + up * hi) * kRenderScale, n, 1, 0),
      m.vertex((a + up * hi) * kRenderScale, n, 0, 0),
    ];
    m.quad(q[0], q[1], q[2], q[3]);
  }

  static void _panel(MeshBuilder m, Vector3 a, Vector3 b, Vector3 up, Vector3 n,
      double h) {
    final q = [
      m.vertex((a + up * 0.05) * kRenderScale, n, 0, 1),
      m.vertex((b + up * 0.05) * kRenderScale, n, 1, 1),
      m.vertex((b + up * h) * kRenderScale, n, 1, 0),
      m.vertex((a + up * h) * kRenderScale, n, 0, 0),
    ];
    m.quad(q[0], q[1], q[2], q[3]);
  }

  static void _board(MeshBuilder m, Vector3 centre, Vector3 side, Vector3 up,
      double hw, double hh, Vector3 offset) {
    final n = offset.length < 1e-9 ? up : offset.normalized;
    final c = centre + offset;
    final q = [
      m.vertex((c - side * hw - up * hh) * kRenderScale, n, 0, 1),
      m.vertex((c + side * hw - up * hh) * kRenderScale, n, 1, 1),
      m.vertex((c + side * hw + up * hh) * kRenderScale, n, 1, 0),
      m.vertex((c - side * hw + up * hh) * kRenderScale, n, 0, 0),
    ];
    m.quad(q[0], q[1], q[2], q[3]);
  }

  /// The apron in front of a building, the driveway joining it to the street,
  /// and the cars standing on it.
  ///
  /// The massing already puts parking between the building and the road — that
  /// is why lots have a front strip at all — but nothing had ever drawn it, so
  /// every plot showed bare ground where its car park was and no way in from
  /// the street. [occupancy] is the share of bays filled, which is what makes
  /// a working district read differently from an empty one.
  ///
  /// Returns the number of cars placed, so a caller can budget them.
  static int emitParking(
    MeshBuilder ground,
    MeshBuilder cars,
    MeshBuilder glass,
    Vector3 centre,
    Vector3 along,
    Vector3 up,
    double halfW,
    double halfD, {
    required int spaces,
    required double occupancy,
    required bool airless,
    int maxCars = 24,
  }) {
    if (spaces <= 0) return 0;
    final side = along.cross(up).normalized;
    // The apron: a strip across the FRONT of the lot, between the building and
    // its street.
    const bayW = 2.6, bayD = 5.2;
    final apronD = math.min(halfD * 0.8, bayD * 1.25);
    final apronMid = centre - along * (halfD - apronD / 2);
    _slab(ground, apronMid, side, along, up, halfW * 0.94, apronD / 2, 0.05);

    // Driveway: a neck from the apron out through the lot line to the curb, so
    // the parking is joined to the road rather than marooned behind a fence.
    final neck = centre - along * (halfD + 1.6);
    _slab(ground, (apronMid + neck) * 0.5, side, along, up,
        math.min(3.2, halfW * 0.5), (apronMid - neck).length / 2, 0.06);

    // Cars, filling from one end so a half-full lot reads as half full rather
    // than as randomly speckled.
    final across = math.max(1, (halfW * 2 * 0.9 / bayW).floor());
    final filled = (spaces * occupancy.clamp(0.0, 1.0))
        .round()
        .clamp(0, math.min(spaces, maxCars))
        .toInt();
    final family = airless ? VehicleKind.airless : VehicleKind.road;
    for (var i = 0; i < filled; i++) {
      final col = i % across;
      final row = i ~/ across;
      if (row > 0) break; // one rank; deeper lots are a later refinement
      final x = (col - (across - 1) / 2) * bayW;
      final at = apronMid + side * x;
      // Nose in, so a rank of cars faces the building.
      final kind = family[(i * 7 + col) % family.length];
      if (kind.lengthM > bayD * 1.6) continue; // a semi does not park here
      VehicleMeshes.emit(cars, glass, kind, at, along, up, u: 0.5);
    }
    return filled;
  }

  static void _slab(MeshBuilder m, Vector3 centre, Vector3 side, Vector3 along,
      Vector3 up, double hw, double hd, double lift) {
    final o = up * lift;
    final q = [
      m.vertex((centre - side * hw - along * hd + o) * kRenderScale, up, 0, 1),
      m.vertex((centre + side * hw - along * hd + o) * kRenderScale, up, 1, 1),
      m.vertex((centre + side * hw + along * hd + o) * kRenderScale, up, 1, 0),
      m.vertex((centre - side * hw + along * hd + o) * kRenderScale, up, 0, 0),
    ];
    m.quad(q[0], q[1], q[2], q[3]);
  }
}
