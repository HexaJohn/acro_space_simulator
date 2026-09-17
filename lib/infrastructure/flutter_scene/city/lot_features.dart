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
  /// [along] is the lot's depth axis and [up] its local radial. Posts and
  /// rails are boxes.
  ///
  /// [coarse] swaps the per-picket posts for structural posts only — rails
  /// and spacing a chain-link fence would have. A picket every 16 cm is
  /// sixteen vertices each, which is what a fence IS from arm's length and
  /// several hundred thousand vertices a colony from anywhere else: lots the
  /// camera resolves as boxes were spending far more mesh on their fences
  /// than on their buildings, and the fences were sub-pixel.
  static void emitFence(
    MeshBuilder m,
    LotEdging kind,
    Vector3 centre,
    Vector3 along,
    Vector3 up,
    double halfW,
    double halfD, {
    bool coarse = false,
  }) {
    if (kind == LotEdging.none) return;
    final side = along.cross(up).normalized;

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
      emitFenceRun(m, kind, a, b, up, coarse: coarse);
    }
  }

  /// One run of fence from [a] to [b], [up] the local radial: the posts, the
  /// rails and (for chain link) the panel. What [emitFence] walks its four
  /// edges with, and what a PLAN-SERVED lot's fence ring walks the real
  /// parcel polygon with (docs/plans/site-access.md §5.5).
  static void emitFenceRun(
    MeshBuilder m,
    LotEdging kind,
    Vector3 a,
    Vector3 b,
    Vector3 up, {
    bool coarse = false,
  }) {
    if (kind == LotEdging.none) return;
    final picket = kind == LotEdging.picket;
    final height = picket ? 1.05 : 2.4;
    final spacing = picket && !coarse ? 0.16 : 2.6;
    final postR = picket ? 0.035 : 0.05;
    final run = b - a;
    final len = run.length;
    if (len < 0.5) return;
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
}
