// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import '../scatter/prop_mesh.dart';
import '../shared/vector3.dart';
import 'proc_shape.dart';

/// Triangle meshes for [ProcShape]s: pure Dart, no GPU, so every invariant the
/// renderer relies on (outward winding, unit normals, bounds equal to
/// [ProcShape.extentM]) is assertable in a headless test.
///
/// Output is a [PropMesh] — the same structure-of-arrays the scatter props
/// hand to `MeshGeometry.fromArrays` — in PART-LOCAL METRES, Z-up, centred on
/// the part origin. Centred, NOT base-origined like a scatter prop: a part's
/// size, attach nodes and inertia are all measured about its origin, and the
/// mesh must agree with them without a corrective offset.
///
/// Winding is CCW seen from OUTSIDE (front faces survive the default backface
/// cull); normals are stated, never left to a generator, because a lattice of
/// touching boxes would average its seams to garbage.
class ProcPartMesh {
  ProcPartMesh._();

  /// The mesh for [shape]. Exhaustive over the sealed hierarchy, so a new
  /// shape cannot be added without stating its geometry here.
  static PropMesh build(ProcShape shape) => switch (shape) {
        ProcSphere s => sphere(diameter: s.diameterM),
        ProcPill p => pill(diameter: p.diameterM, length: p.lengthM),
        ProcTruss t => truss(
            width: t.widthM, length: t.lengthM, strutFrac: t.strutFrac),
        ProcPlate p => plate(
            width: p.widthM, height: p.heightM, thickness: p.thicknessM),
      };

  /// UV sphere, poles on ±Z: a pill whose cylinder section has zero length.
  static PropMesh sphere({
    required double diameter,
    int segments = 32,
    int capRings = 8,
  }) =>
      pill(
        diameter: diameter,
        length: diameter,
        segments: segments,
        capRings: capRings,
      );

  /// Capsule about Z: cylinder of diameter [diameter], hemispherical caps,
  /// [length] pole to pole. [length] == [diameter] degenerates cleanly to a
  /// sphere (the cylinder row is skipped, not emitted at zero height).
  ///
  /// Built as one latitude sweep from the +Z pole so the cap/cylinder seam
  /// shares vertices — and therefore normals — with both sides: a capsule's
  /// surface is tangent-continuous there and the mesh must read that way.
  static PropMesh pill({
    required double diameter,
    required double length,
    int segments = 32,
    int capRings = 8,
  }) {
    final r = diameter / 2;
    final hc = math.max(0.0, length / 2 - r); // cylinder half-height
    // Rows of (z, ring radius, normal) from +Z pole to -Z pole. The normal is
    // radial on the cylinder and polar on the caps; both are (nr, nz) pairs
    // swept around Z below.
    final rows = <({double z, double rad, double nr, double nz})>[];
    for (var i = 0; i <= capRings; i++) {
      final a = (math.pi / 2) * i / capRings;
      rows.add((
        z: hc + r * math.cos(a),
        rad: r * math.sin(a),
        nr: math.sin(a),
        nz: math.cos(a),
      ));
    }
    if (hc > 0) rows.add((z: -hc, rad: r, nr: 1, nz: 0));
    for (var i = 1; i <= capRings; i++) {
      final a = math.pi / 2 + (math.pi / 2) * i / capRings;
      rows.add((
        z: -hc + r * math.cos(a),
        rad: r * math.sin(a),
        nr: math.sin(a),
        nz: math.cos(a),
      ));
    }

    final positions = <double>[];
    final normals = <double>[];
    final texCoords = <double>[];
    final indices = <int>[];
    for (var ri = 0; ri < rows.length; ri++) {
      final row = rows[ri];
      final v = ri / (rows.length - 1);
      for (var s = 0; s <= segments; s++) {
        final theta = 2 * math.pi * s / segments;
        final c = math.cos(theta), sn = math.sin(theta);
        positions.addAll([row.rad * c, row.rad * sn, row.z]);
        normals.addAll([row.nr * c, row.nr * sn, row.nz]);
        texCoords.addAll([s / segments, v]);
      }
    }
    for (var ri = 0; ri < rows.length - 1; ri++) {
      for (var s = 0; s < segments; s++) {
        final a = ri * (segments + 1) + s;
        final b = a + segments + 1;
        // Outward in RAW coordinates (CCW from outside; positive signed
        // volume) — deliberately NOT `uvSphereZUp`'s pattern, which is wound
        // for the planet pipeline's image-level chirality flip. Parts render
        // unflipped, where that winding is the backface veil `VesselNodes`
        // already fixed once. The pole rows emit zero-area triangles, which
        // every backend accepts.
        indices.addAll([a, b, a + 1, a + 1, b, b + 1]);
      }
    }
    return _pack(positions, normals, texCoords, indices);
  }

  /// Lattice girder: see [ProcTruss]. Built entirely from oriented boxes —
  /// four longerons, four ring rungs per bay boundary, one diagonal per face
  /// per bay, zig-zagging so adjacent bays brace opposite ways.
  static PropMesh truss({
    required double width,
    required double length,
    double strutFrac = 0.12,
  }) {
    final b = _Builder();
    final t = width * strutFrac; // longeron thickness
    final h = width / 2;
    final hz = length / 2;
    final c = h - t / 2; // longeron centreline offset from the axis
    final bays = math.max(1, (length / width).round());
    final bayLen = length / bays;

    const x = Vector3(1, 0, 0), y = Vector3(0, 1, 0), z = Vector3(0, 0, 1);

    // Longerons: full-length corner chords.
    for (final sx in [-1.0, 1.0]) {
      for (final sy in [-1.0, 1.0]) {
        b.box(Vector3(sx * c, sy * c, 0), z, hz, x, t / 2, y, t / 2);
      }
    }
    // Ring rungs at each bay boundary. Slightly thinner than the longerons and
    // run to the longeron CENTRELINES, so their faces sink inside the chords
    // instead of lying coplanar with them (coplanar faces shimmer).
    final rt = t * 0.45;
    for (var i = 0; i <= bays; i++) {
      // End rings sit flush INSIDE the ±length/2 faces (their outer surface on
      // the face, not their centreline), so the girder's mesh ends exactly
      // where its declared box does and two stacked girders' rings meet
      // instead of interpenetrating.
      final zi = (-hz + i * bayLen).clamp(-hz + rt, hz - rt);
      for (final s in [-1.0, 1.0]) {
        b.box(Vector3(0, s * c, zi), x, c, y, rt, z, rt); // along X
        b.box(Vector3(s * c, 0, zi), y, c, z, rt, x, rt); // along Y
      }
    }
    // Diagonals: one per face per bay, alternating slope. The strut runs
    // between longeron centrelines across the face, in the face's own plane.
    // Its half-length is pulled in by its own corner spread (dt · across /
    // bayLen is the z the strut's cross-section adds past its endpoint), so
    // an end bay's diagonal cannot poke past the ±length/2 face and break the
    // "mesh fills exactly the declared box" contract; the shortfall lands
    // inside the rung it meets.
    final dt = t * 0.35;
    final across = 2 * c;
    for (var i = 0; i < bays; i++) {
      final z0 = -hz + i * bayLen;
      final zMid = z0 + bayLen / 2;
      final slope = i.isEven ? 1.0 : -1.0;
      final halfLen = 0.5 * math.sqrt(across * across + bayLen * bayLen) -
          dt * across / bayLen;
      for (final s in [-1.0, 1.0]) {
        // Faces normal to ±Y: diagonal sweeps across X as z rises.
        final uY = Vector3(slope * across, 0, bayLen).normalized;
        b.box(Vector3(0, s * c, zMid), uY, halfLen, y, dt, uY.cross(y), dt);
        // Faces normal to ±X: diagonal sweeps across Y.
        final uX = Vector3(0, slope * across, bayLen).normalized;
        b.box(Vector3(s * c, 0, zMid), uX, halfLen, x, dt, uX.cross(x), dt);
      }
    }
    return b.pack();
  }

  /// Axis-aligned rectangular plate, thin in Z.
  static PropMesh plate({
    required double width,
    required double height,
    required double thickness,
  }) {
    final b = _Builder();
    b.box(
      Vector3.zero,
      const Vector3(1, 0, 0),
      width / 2,
      const Vector3(0, 1, 0),
      height / 2,
      const Vector3(0, 0, 1),
      thickness / 2,
    );
    return b.pack();
  }

  static PropMesh _pack(
    List<double> positions,
    List<double> normals,
    List<double> texCoords,
    List<int> indices,
  ) =>
      PropMesh(
        positions: Float32List.fromList(positions),
        normals: Float32List.fromList(normals),
        texCoords: Float32List.fromList(texCoords),
        indices: Uint32List.fromList(indices),
      );
}

/// Accumulates oriented boxes into one buffer set. 24 vertices per box —
/// each face owns its corners — because a strut is a hard-edged solid and
/// shared corners would round its lighting.
class _Builder {
  final List<double> positions = [];
  final List<double> normals = [];
  final List<double> texCoords = [];
  final List<int> indices = [];

  /// A box at [centre] spanning ±[hu]·[u] ±[hv]·[v] ±[hw]·[w]. The axes must
  /// be orthonormal and RIGHT-HANDED in the cyclic order u, v, w (u x v = w):
  /// each face is wound with a (normal, tangent, bitangent) triple whose
  /// tangent x bitangent = normal, which is what makes every face CCW from
  /// outside.
  void box(
    Vector3 centre,
    Vector3 u,
    double hu,
    Vector3 v,
    double hv,
    Vector3 w,
    double hw,
  ) {
    void face(Vector3 n, double hn, Vector3 a, double ha, Vector3 b, double hb) {
      final o = centre + n * hn;
      final base = positions.length ~/ 3;
      final corners = [
        o - a * ha - b * hb,
        o + a * ha - b * hb,
        o + a * ha + b * hb,
        o - a * ha + b * hb,
      ];
      for (final p in corners) {
        positions.addAll([p.x, p.y, p.z]);
        normals.addAll([n.x, n.y, n.z]);
        texCoords.addAll([0, 0]);
      }
      indices.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
    }

    face(u, hu, v, hv, w, hw);
    face(-u, hu, w, hw, v, hv);
    face(v, hv, w, hw, u, hu);
    face(-v, hv, u, hu, w, hw);
    face(w, hw, u, hu, v, hv);
    face(-w, hw, v, hv, u, hu);
  }

  PropMesh pack() => PropMesh(
        positions: Float32List.fromList(positions),
        normals: Float32List.fromList(normals),
        texCoords: Float32List.fromList(texCoords),
        indices: Uint32List.fromList(indices),
      );
}
