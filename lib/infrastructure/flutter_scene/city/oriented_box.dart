// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// One box, wound the way this engine wants it.
///
/// Every piece of city furniture — a bollard, a bridge pier, a girder, a
/// signal head — is a box in some local frame, and getting the winding right
/// is the entire difficulty. `MeshBuilder.triangle(a, b, c)` emits `(a, c, b)`,
/// so it REVERSES what it is handed; compose that with the engine's front-face
/// convention and the plan-axis handedness and the sign is genuinely hard to
/// derive. It has been derived wrong four separate times in this codebase, and
/// a box facing the wrong way does not look wrong, it looks ABSENT.
///
/// So there is now exactly one copy of it, measured against geometry known to
/// render (see `test/colony/scale_rig_test.dart`, which pins it against the
/// building generator's own walls). Anything that needs a box calls this.
library;

import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';

class OrientedBox {
  const OrientedBox._();

  /// A box centred at [c], with half-extents [hx]/[hy]/[hz] along
  /// [ex]/[ey]/[ez]. Coordinates are in METRES and scaled to scene units here.
  ///
  /// [u]/[v] set the texture coordinate every vertex carries. A flat lookup is
  /// what the palette-style materials want; pass the middle of a band.
  ///
  /// [unitScale] converts the caller's units to scene units. The default suits
  /// geometry emitted straight into a scene mesh; pass 1.0 for geometry that
  /// is INSTANCED, because a building's instance transform already carries the
  /// metres-to-scene factor and applying it twice makes the mesh a thousandth
  /// of its size — present, drawn, and far too small to see.
  static void emit(
    MeshBuilder m,
    Vector3 c,
    Vector3 ex,
    Vector3 ey,
    Vector3 ez,
    double hx,
    double hy,
    double hz, {
    double u = 0.5,
    double v = 0.5,
    double unitScale = kRenderScale,
  }) {
    final p = <Vector3>[
      c - ex * hx - ey * hy - ez * hz,
      c + ex * hx - ey * hy - ez * hz,
      c + ex * hx + ey * hy - ez * hz,
      c - ex * hx + ey * hy - ez * hz,
      c - ex * hx - ey * hy + ez * hz,
      c + ex * hx - ey * hy + ez * hz,
      c + ex * hx + ey * hy + ez * hz,
      c - ex * hx + ey * hy + ez * hz,
    ];
    final n = [ez, ez * -1, ex, ex * -1, ey, ey * -1];
    // Every face is listed so its own winding AGREES with the normal beside
    // it; the single reversal inside `quad`/`triangle` then flips all six
    // together. Listed any other way, half the box comes out inside out — and
    // only half of it disappears, which reads as a modelling mistake rather
    // than a winding one.
    const faces = [
      [4, 5, 6, 7],
      [3, 2, 1, 0],
      [2, 6, 5, 1],
      [0, 4, 7, 3],
      [3, 7, 6, 2],
      [1, 5, 4, 0],
    ];
    for (var f = 0; f < faces.length; f++) {
      final q = [
        for (final i in faces[f]) m.vertex(p[i] * unitScale, n[f], u, v)
      ];
      m.quad(q[0], q[1], q[2], q[3]);
    }
  }

  /// An upright box standing ON the ground at [base], [heightM] tall.
  static void upright(
    MeshBuilder m,
    Vector3 base,
    Vector3 along,
    Vector3 up,
    double widthM,
    double depthM,
    double heightM, {
    double u = 0.5,
    double v = 0.5,
    double unitScale = kRenderScale,
  }) {
    final side = along.cross(up).normalized;
    emit(m, base + up * (heightM / 2), side, along, up, widthM / 2, depthM / 2,
        heightM / 2,
        u: u, v: v, unitScale: unitScale);
  }

  /// A box spanning [a] to [b] — a girder, a rail, a cross member.
  static void span(
    MeshBuilder m,
    Vector3 a,
    Vector3 b,
    Vector3 up,
    double widthM,
    double heightM, {
    double u = 0.5,
    double v = 0.5,
  }) {
    final d = b - a;
    if (d.length < 1e-6) return;
    final along = d.normalized;
    final side = along.cross(up).normalized;
    emit(m, (a + b) * 0.5, side, along, up, widthM / 2, d.length / 2,
        heightM / 2,
        u: u, v: v);
  }
}
