// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Meshes one cubed-sphere chunk as a thin radial shell (phase 4a).
///
/// The box mesher (`infrastructure/.../terrain_mesher.dart`) samples an
/// axis-aligned lattice, which cannot tile a curved cell. This one samples the
/// chunk's OWN `(s, t, r)` space: lateral position runs across the cell's face
/// coordinates, radial position across the band that can contain the
/// isosurface. Surface Nets runs on that lattice as if it were cubic — its
/// topology only cares about sample connectivity — and the resulting vertices
/// are mapped back to the body-fixed frame afterwards.
///
/// Only the shell is meshed, never a solid box down to the core
/// (`docs/plans/terrain-lod.md` §1). At high levels the band is thin, and that
/// is what keeps voxel count bounded as chunk count grows.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../shared/vector3.dart';
import 'cubed_sphere.dart';
import 'surface_nets.dart';
import 'terrain_field.dart';

/// A meshed chunk, positioned RELATIVE TO [anchorBF].
///
/// Absolute body-frame coordinates sit ~1e6 m from the origin; storing those in
/// a float32 vertex buffer cancels catastrophically against a float32 node
/// transform and jitters violently up close. The caller places [anchorBF]
/// through the floating origin and uploads the small local vertices — same
/// rule the box mesher follows.
class CellMesh {
  CellMesh({
    required this.chunk,
    required this.anchorBF,
    required this.mesh,
    required this.radialSamples,
    required this.innerRadiusM,
    required this.outerRadiusM,
    required this.clipped,
    this.surfaceTriangleCount = 0,
    this.surfaceVertexCount = 0,
  });

  final ChunkKey chunk;

  /// Body-fixed point the vertices are relative to (the cell centre, on the
  /// ground).
  final Vector3 anchorBF;

  final SurfaceMesh mesh;

  /// Radial samples actually used — the shell's thickness in voxels.
  final int radialSamples;

  final double innerRadiusM;
  final double outerRadiusM;

  /// True when the isosurface reached a radial edge of the band, i.e. the shell
  /// was too thin and terrain got cut off. Should never fire for a field whose
  /// relief stays inside `radius +- amplitude`; it is a real self-check rather
  /// than a formality, because the band is derived from a FINITE probe of the
  /// cell and a tall enough spike between probes would escape it.
  final bool clipped;

  /// Triangles in the surface proper, excluding the skirt. `mesh.triangleCount
  /// - surfaceTriangleCount` is what the apron cost.
  final int surfaceTriangleCount;

  /// Vertices in the surface proper. Skirt vertices are appended after these,
  /// so any index `>= surfaceVertexCount` belongs to the apron.
  final int surfaceVertexCount;

  bool get isEmpty => mesh.isEmpty;
}

/// Mesh [chunk] of [field]'s surface.
///
/// [resolution] is lateral cells across the chunk; the radial count is derived
/// so voxels stay roughly cubic, capped by [maxRadialSamples]. One apron cell
/// is added on each lateral side so Surface Nets' omitted boundary faces fall
/// OUTSIDE the cell proper and neighbouring chunks at the same level overlap
/// instead of cracking. (Cracks at a LEVEL boundary are a different problem —
/// that is phase 4b, skirts.)
CellMesh meshTerrainCell(
  TerrainField field,
  ChunkKey chunk, {
  int resolution = 32,
  int maxRadialSamples = 48,
  double marginVoxels = 2.0,
  double skirtVoxels = 2.5,
}) {
  assert(resolution >= 2);

  // --- 1. The radial band this cell needs -----------------------------------
  // Probe ground radius across the cell. Denser than a corner check: relief
  // between corners is exactly what would otherwise be clipped.
  final probe = math.min(resolution + 1, 17);
  var minGround = double.infinity, maxGround = -double.infinity;
  for (var a = 0; a < probe; a++) {
    final s = chunk.s0 + (chunk.s1 - chunk.s0) * a / (probe - 1);
    for (var b = 0; b < probe; b++) {
      final t = chunk.t0 + (chunk.t1 - chunk.t0) * b / (probe - 1);
      final d = directionOf(chunk.face, s, t);
      final g = field.groundRadiusAt(d.x, d.y, d.z);
      if (g < minGround) minGround = g;
      if (g > maxGround) maxGround = g;
    }
  }

  // Approximate metres per lateral cell — the target voxel size.
  final lateralM =
      math.max(1e-3, chunk.circumradiusM(field.radius) * 2.0 / resolution);

  // Pad the band so a peak that fell BETWEEN probes still fits. Both terms
  // scale with the cell: a few voxels, plus a slice of the relief this cell
  // actually spans. Deliberately not a fraction of the body's global
  // amplitude — that is constant in metres, so at high levels it would dwarf
  // the voxel size and the shell would stop thinning just as chunk count grows.
  final pad = marginVoxels * lateralM + (maxGround - minGround) * 0.25;
  final rLo = minGround - pad;
  final rHi = maxGround + pad;

  final radialCells =
      ((rHi - rLo) / lateralM).ceil().clamp(2, maxRadialSamples);
  final nr = radialCells + 1; // samples

  // --- 2. Lattice -> body-frame mapping ------------------------------------
  final n = resolution + 3; // resolution cells + 2 apron cells -> +3 samples
  final ds = (chunk.s1 - chunk.s0) / resolution;
  final dt = (chunk.t1 - chunk.t0) / resolution;
  final dr = (rHi - rLo) / (nr - 1);

  // Lattice index 1 sits on the cell's low edge, index resolution+1 on its
  // high edge; 0 and resolution+2 are the apron.
  Vector3 bodyAt(double fi, double fj, double fk) {
    final s = chunk.s0 + (fi - 1) * ds;
    final t = chunk.t0 + (fj - 1) * dt;
    final r = rLo + fk * dr;
    return directionOf(chunk.face, s, t) * r;
  }

  // --- 3. Sample the field on that lattice ---------------------------------
  // voxelSize 1 / origin 0, so Surface Nets' "world" coordinates ARE lattice
  // coordinates and the mapping above is the only place geometry is decided.
  final grid = DensityGrid.sample(
    (x, y, z) {
      final p = bodyAt(x, y, z);
      return field.density(p.x, p.y, p.z);
    },
    nx: n,
    ny: n,
    nz: nr,
    voxelSize: 1.0,
  );

  // Self-check: the innermost shell must be entirely solid and the outermost
  // entirely air, or the band failed to contain the surface.
  var clipped = false;
  for (var j = 0; j < n && !clipped; j++) {
    for (var i = 0; i < n; i++) {
      if (grid.at(i, j, 0) >= 0 || grid.at(i, j, nr - 1) <= 0) {
        clipped = true;
        break;
      }
    }
  }

  final anchorDir = chunk.centreDirection;
  final anchorBF = anchorDir *
      field.groundRadiusAt(anchorDir.x, anchorDir.y, anchorDir.z);

  final lattice = surfaceNets(grid);
  if (lattice.isEmpty) {
    return CellMesh(
      chunk: chunk,
      anchorBF: anchorBF,
      mesh: lattice,
      radialSamples: nr,
      innerRadiusM: rLo,
      outerRadiusM: rHi,
      clipped: clipped,
    );
  }

  // --- 4. Map vertices to the body frame, re-derive normals ----------------
  // The lattice-space normals Surface Nets produced are gradients of the
  // WARPED grid and are wrong once vertices are unwarped, so they are
  // discarded. The field is analytic, so a central difference in body space is
  // both cheaper to reason about and more accurate.
  final src = lattice.positions;
  final count = src.length ~/ 3;
  final positions = Float32List(src.length);
  final normals = Float32List(src.length);
  final eps = lateralM * 0.5;
  for (var v = 0; v < count; v++) {
    final o = v * 3;
    final p = bodyAt(src[o], src[o + 1], src[o + 2]);
    positions[o] = p.x - anchorBF.x;
    positions[o + 1] = p.y - anchorBF.y;
    positions[o + 2] = p.z - anchorBF.z;

    // Density rises from solid (<0) to air (>0), so +grad points outward.
    final gx = field.density(p.x + eps, p.y, p.z) -
        field.density(p.x - eps, p.y, p.z);
    final gy = field.density(p.x, p.y + eps, p.z) -
        field.density(p.x, p.y - eps, p.z);
    final gz = field.density(p.x, p.y, p.z + eps) -
        field.density(p.x, p.y, p.z - eps);
    final len = math.sqrt(gx * gx + gy * gy + gz * gz);
    if (len > 1e-12) {
      normals[o] = gx / len;
      normals[o + 1] = gy / len;
      normals[o + 2] = gz / len;
    } else {
      // Degenerate flat sample: fall back to straight up.
      final d = p.normalized;
      normals[o] = d.x;
      normals[o + 1] = d.y;
      normals[o + 2] = d.z;
    }
  }

  // --- 5. Skirts (phase 4b) ------------------------------------------------
  final skirted = skirtVoxels <= 0
      ? SurfaceMesh(
          positions: positions,
          normals: normals,
          indices: lattice.indices,
          normalMode: NormalMode.gradient,
        )
      : _addSkirt(
          positions: positions,
          normals: normals,
          indices: lattice.indices,
          anchorBF: anchorBF,
          depthM: skirtVoxels * lateralM,
        );

  return CellMesh(
    chunk: chunk,
    anchorBF: anchorBF,
    mesh: skirted,
    radialSamples: nr,
    innerRadiusM: rLo,
    outerRadiusM: rHi,
    clipped: clipped,
    surfaceTriangleCount: lattice.indices.length ~/ 3,
    surfaceVertexCount: count,
  );
}

/// Hang an apron inward from the mesh's open boundary.
///
/// Across an LOD boundary the two sides sample the field at different rates, so
/// their vertices do not meet and a crack opens (`docs/plans/terrain-lod.md`
/// §3). A skirt does not close the crack — it puts opaque geometry BEHIND it,
/// so nothing shows through. Cheap, needs no change to the mesher, and does not
/// block Transvoxel later if it ever proves visible.
///
/// The boundary is found topologically: an edge used by exactly one triangle is
/// an open edge. Because the radial band fully contains the isosurface (the
/// `clipped` self-check), those open edges are only ever the chunk's lateral
/// perimeter — never a hole in the middle of the sheet.
///
/// Skirt vertices inherit the surface normal of the boundary vertex they hang
/// from, rather than a sideways one. The apron is meant to be invisible; giving
/// it its own shading would trade a crack for a dark rim.
SurfaceMesh _addSkirt({
  required Float32List positions,
  required Float32List normals,
  required Uint32List indices,
  required Vector3 anchorBF,
  required double depthM,
}) {
  final count = positions.length ~/ 3;

  // Count edge uses. Key packs the ordered pair into one int (Dart ints are
  // 64-bit, and count never approaches 2^31).
  final uses = <int, int>{};
  int keyOf(int a, int b) => a < b ? a * count + b : b * count + a;
  for (var t = 0; t < indices.length; t += 3) {
    final a = indices[t], b = indices[t + 1], c = indices[t + 2];
    uses.update(keyOf(a, b), (v) => v + 1, ifAbsent: () => 1);
    uses.update(keyOf(b, c), (v) => v + 1, ifAbsent: () => 1);
    uses.update(keyOf(c, a), (v) => v + 1, ifAbsent: () => 1);
  }

  // Re-walk the triangles to recover boundary edges WITH their orientation, so
  // the skirt quads wind consistently with the surface they hang from.
  final boundary = <List<int>>[];
  for (var t = 0; t < indices.length; t += 3) {
    final tri = [indices[t], indices[t + 1], indices[t + 2]];
    for (var e = 0; e < 3; e++) {
      final a = tri[e], b = tri[(e + 1) % 3];
      if (uses[keyOf(a, b)] == 1) boundary.add([a, b]);
    }
  }
  if (boundary.isEmpty) {
    return SurfaceMesh(
      positions: positions,
      normals: normals,
      indices: indices,
      normalMode: NormalMode.gradient,
    );
  }

  // One skirt vertex per boundary VERTEX (shared between its two edges).
  final skirtOf = <int, int>{};
  for (final e in boundary) {
    for (final v in e) {
      skirtOf.putIfAbsent(v, () => skirtOf.length + count);
    }
  }

  final total = count + skirtOf.length;
  final outPos = Float32List(total * 3);
  final outNrm = Float32List(total * 3);
  outPos.setRange(0, positions.length, positions);
  outNrm.setRange(0, normals.length, normals);
  for (final entry in skirtOf.entries) {
    final src = entry.key * 3, dst = entry.value * 3;
    // Inward means toward the body centre, so drop along the radial of the
    // vertex's ABSOLUTE position — positions here are anchor-relative.
    final world = anchorBF +
        Vector3(positions[src], positions[src + 1], positions[src + 2]);
    final down = world.normalized * -depthM;
    outPos[dst] = positions[src] + down.x;
    outPos[dst + 1] = positions[src + 1] + down.y;
    outPos[dst + 2] = positions[src + 2] + down.z;
    outNrm[dst] = normals[src];
    outNrm[dst + 1] = normals[src + 1];
    outNrm[dst + 2] = normals[src + 2];
  }

  final outIdx = Uint32List(indices.length + boundary.length * 6);
  outIdx.setRange(0, indices.length, indices);
  var w = indices.length;
  for (final e in boundary) {
    final a = e[0], b = e[1];
    final a2 = skirtOf[a]!, b2 = skirtOf[b]!;
    outIdx[w++] = a;
    outIdx[w++] = b;
    outIdx[w++] = b2;
    outIdx[w++] = a;
    outIdx[w++] = b2;
    outIdx[w++] = a2;
  }

  return SurfaceMesh(
    positions: outPos,
    normals: outNrm,
    indices: outIdx,
    normalMode: NormalMode.gradient,
  );
}
