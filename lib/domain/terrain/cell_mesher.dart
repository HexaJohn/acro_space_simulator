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
import 'terrain_brush.dart';
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
///
/// ## Why the field is sampled per COLUMN, not per voxel
///
/// The base relief is a height field: its density along one radial is
/// `r - (radius + h(dir))`, and `h` depends only on the direction. Every voxel
/// in a lateral column shares that direction, so `h` is evaluated ONCE per
/// column and the ~50 voxels above it are pure arithmetic. `h` is the expensive
/// part (erosion fBm + ridged blend + crater field on a cratered body), so this
/// is a ~voxel-band-height× reduction in field cost — the difference between
/// meshing a Moon chunk in hundreds of milliseconds and a handful.
///
/// [TerrainEdits] are genuinely 3D and cannot be column-collapsed, so columns
/// whose direction an edit covers fall back to per-voxel composition — but only
/// those columns, and only when the chunk has edits at all.
CellMesh meshTerrainCell(
  TerrainField field,
  ChunkKey chunk, {
  int resolution = 32,
  int maxRadialSamples = 48,
  double marginVoxels = 2.0,
  double skirtVoxels = 2.5,
}) {
  assert(resolution >= 2);

  final n = resolution + 3; // resolution cells + 2 apron cells -> +3 samples
  final ds = (chunk.s1 - chunk.s0) / resolution;
  final dt = (chunk.t1 - chunk.t0) / resolution;

  // --- 1. The heavy pass: one direction + one ground height per column ------
  // This lattice doubles as the band probe the old 17x17 pre-pass did — it is
  // strictly denser, so relief between samples is bounded the same way.
  final dirX = Float64List(n * n);
  final dirY = Float64List(n * n);
  final dirZ = Float64List(n * n);
  final ground = Float64List(n * n); // radius + h(dir), base relief only
  var minGround = double.infinity, maxGround = -double.infinity;
  for (var j = 0; j < n; j++) {
    final t = chunk.t0 + (j - 1) * dt;
    for (var i = 0; i < n; i++) {
      final s = chunk.s0 + (i - 1) * ds;
      final d = directionOf(chunk.face, s, t);
      final c = j * n + i;
      dirX[c] = d.x;
      dirY[c] = d.y;
      dirZ[c] = d.z;
      final g = field.radius + field.heightInDirection(d.x, d.y, d.z);
      ground[c] = g;
      if (g < minGround) minGround = g;
      if (g > maxGround) maxGround = g;
    }
  }

  // Approximate metres per lateral cell — the target voxel size.
  final lateralM =
      math.max(1e-3, chunk.circumradiusM(field.radius) * 2.0 / resolution);

  // --- 2. Edit candidates, resolved once per column --------------------------
  // `edits.at` is a handful of map probes; doing it per column instead of per
  // voxel keeps the index out of the hot loop. Null list = untouched column.
  final edits = field.edits;
  List<List<TerrainBrush>?>? columnBrushes;
  var editLo = double.infinity, editHi = double.negativeInfinity;
  if (edits != null && edits.isNotEmpty) {
    for (var c = 0; c < n * n; c++) {
      final cands = edits.at(Vector3(dirX[c], dirY[c], dirZ[c]));
      if (cands.isEmpty) continue;
      columnBrushes ??= List<List<TerrainBrush>?>.filled(n * n, null);
      columnBrushes[c] = cands;
      // An edit can move the surface outside the base band (a bowl digs below
      // it, a rim stands above it). Its influence sphere bounds both, so the
      // band is widened to that — conservative, and the `clipped` self-check
      // still guards the construction.
      for (final b in cands) {
        final centreR = b.centreBF.length;
        if (centreR - b.boundingRadiusM < editLo) {
          editLo = centreR - b.boundingRadiusM;
        }
        if (centreR + b.boundingRadiusM > editHi) {
          editHi = centreR + b.boundingRadiusM;
        }
      }
    }
  }

  // --- 3. The radial band ----------------------------------------------------
  // Pad the band so a peak that fell BETWEEN samples still fits. Both terms
  // scale with the cell: a few voxels, plus a slice of the relief this cell
  // actually spans. Deliberately not a fraction of the body's global
  // amplitude — that is constant in metres, so at high levels it would dwarf
  // the voxel size and the shell would stop thinning just as chunk count grows.
  final pad = marginVoxels * lateralM + (maxGround - minGround) * 0.25;
  var rLo = minGround - pad;
  var rHi = maxGround + pad;
  if (columnBrushes != null) {
    rLo = math.min(rLo, editLo - marginVoxels * lateralM);
    rHi = math.max(rHi, editHi + marginVoxels * lateralM);
  }

  final radialCells =
      ((rHi - rLo) / lateralM).ceil().clamp(2, maxRadialSamples);
  final nr = radialCells + 1; // samples
  final dr = (rHi - rLo) / (nr - 1);

  // Lattice index 1 sits on the cell's low edge, index resolution+1 on its
  // high edge; 0 and resolution+2 are the apron.
  Vector3 bodyAt(double fi, double fj, double fk) {
    final s = chunk.s0 + (fi - 1) * ds;
    final t = chunk.t0 + (fj - 1) * dt;
    final r = rLo + fk * dr;
    return directionOf(chunk.face, s, t) * r;
  }

  // --- 4. Fill the density lattice ------------------------------------------
  // voxelSize 1 / origin 0, so Surface Nets' "world" coordinates ARE lattice
  // coordinates and the mapping above is the only place geometry is decided.
  // Base density along a column is `r - ground`, exactly what
  // `TerrainField.density` computes for these positions (the direction is the
  // column's own, `|dir * r| == r`); only edited columns compose brushes.
  final samples = Float64List(n * n * nr);
  for (var k = 0; k < nr; k++) {
    final r = rLo + k * dr;
    final slab = k * n * n;
    for (var c = 0; c < n * n; c++) {
      final base = r - ground[c];
      final brushes = columnBrushes?[c];
      if (brushes == null) {
        samples[slab + c] = base;
      } else {
        final p = Vector3(dirX[c] * r, dirY[c] * r, dirZ[c] * r);
        var d = base;
        for (final b in brushes) {
          d = b.apply(d, p);
        }
        samples[slab + c] = d;
      }
    }
  }
  final grid = DensityGrid(
    samples: samples,
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

  // Bilinear ground radius at fractional lattice coordinates, clamped at the
  // lattice border (one-sided differences there).
  double groundAt(double fi, double fj) {
    final ci = fi.clamp(0.0, (n - 1).toDouble());
    final cj = fj.clamp(0.0, (n - 1).toDouble());
    final i0 = ci.floor(), j0 = cj.floor();
    final i1 = math.min(i0 + 1, n - 1), j1 = math.min(j0 + 1, n - 1);
    final fx = ci - i0, fy = cj - j0;
    final g00 = ground[j0 * n + i0], g10 = ground[j0 * n + i1];
    final g01 = ground[j1 * n + i0], g11 = ground[j1 * n + i1];
    final g0 = g00 + (g10 - g00) * fx;
    final g1 = g01 + (g11 - g01) * fx;
    return g0 + (g1 - g0) * fy;
  }

  // Whether a vertex inside cell (floor(fi), floor(fj)) has an edited column
  // among the four it interpolates between.
  bool nearEdit(double fi, double fj) {
    final touched = columnBrushes;
    if (touched == null) return false;
    final i0 = fi.floor().clamp(0, n - 2), j0 = fj.floor().clamp(0, n - 2);
    return touched[j0 * n + i0] != null ||
        touched[j0 * n + i0 + 1] != null ||
        touched[(j0 + 1) * n + i0] != null ||
        touched[(j0 + 1) * n + i0 + 1] != null;
  }

  // --- 5. Map vertices to the body frame, re-derive normals ----------------
  // The lattice-space normals Surface Nets produced are gradients of the
  // WARPED grid and are wrong once vertices are unwarped, so they are
  // discarded. On the base relief the surface is the height field
  // `P(s,t) = dir(s,t) * g(s,t)`, so the normal is the (cheap, analytic)
  // cross product of its tangents, with `dh` read off the ground lattice —
  // no further field evaluations. Near an edit the surface is genuinely 3D
  // and the normal falls back to a central difference of the composed field.
  final src = lattice.positions;
  final count = src.length ~/ 3;
  final positions = Float32List(src.length);
  final normals = Float32List(src.length);
  final eps = lateralM * 0.5;
  for (var v = 0; v < count; v++) {
    final o = v * 3;
    final fi = src[o], fj = src[o + 1], fk = src[o + 2];
    final p = bodyAt(fi, fj, fk);
    positions[o] = p.x - anchorBF.x;
    positions[o + 1] = p.y - anchorBF.y;
    positions[o + 2] = p.z - anchorBF.z;

    var nx = 0.0, ny = 0.0, nz = 0.0;
    if (nearEdit(fi, fj)) {
      // Density rises from solid (<0) to air (>0), so +grad points outward.
      nx = field.density(p.x + eps, p.y, p.z) -
          field.density(p.x - eps, p.y, p.z);
      ny = field.density(p.x, p.y + eps, p.z) -
          field.density(p.x, p.y - eps, p.z);
      nz = field.density(p.x, p.y, p.z + eps) -
          field.density(p.x, p.y, p.z - eps);
    } else {
      final s = chunk.s0 + (fi - 1) * ds;
      final t = chunk.t0 + (fj - 1) * dt;
      final g = groundAt(fi, fj);
      final r = rLo + fk * dr;
      final dir = p / r;
      // Tangents of dir(s,t), central-differenced in face coordinates (pure
      // algebra — no noise), and dh off the ground lattice.
      final dirS = (directionOf(chunk.face, s + ds * 0.5, t) -
              directionOf(chunk.face, s - ds * 0.5, t)) /
          ds;
      final dirT = (directionOf(chunk.face, s, t + dt * 0.5) -
              directionOf(chunk.face, s, t - dt * 0.5)) /
          dt;
      final hs = (groundAt(fi + 1, fj) - groundAt(fi - 1, fj)) / (2 * ds);
      final ht = (groundAt(fi, fj + 1) - groundAt(fi, fj - 1)) / (2 * dt);
      final ps = dirS * g + dir * hs;
      final pt = dirT * g + dir * ht;
      var cr = ps.cross(pt);
      if (cr.dot(dir) < 0) cr = -cr;
      nx = cr.x;
      ny = cr.y;
      nz = cr.z;
    }
    final len = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 1e-12) {
      normals[o] = nx / len;
      normals[o + 1] = ny / len;
      normals[o + 2] = nz / len;
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

/// Filter [cell]'s index buffer against finer chunks that now cover parts of
/// its footprint: a triangle whose centroid direction falls inside any chunk
/// in [masked] is dropped. The coarse chunk then renders AROUND its refined
/// quadrants instead of underneath them — the geometric LOD mask.
///
/// The centroid decides boundary triangles whole, so the cut can be ragged by
/// up to one coarse cell; the finer chunk's apron (skirt) hangs over exactly
/// that seam. [interiorRemaining] counts surviving triangles whose centroid
/// is INSIDE [cell]'s own footprint — when it reaches zero every quadrant is
/// refined and the caller can drop the chunk outright (the apron ring that
/// spills outside the footprint never blocks completion).
({Uint32List indices, int interiorRemaining}) maskCellIndices(
  CellMesh cell,
  Set<ChunkKey> masked,
) {
  final src = cell.mesh.indices;
  final pos = cell.mesh.positions;
  final a = cell.anchorBF;
  final out = Uint32List(src.length);
  var w = 0;
  var interior = 0;
  for (var t = 0; t < src.length; t += 3) {
    final i0 = src[t] * 3, i1 = src[t + 1] * 3, i2 = src[t + 2] * 3;
    final cx = a.x + (pos[i0] + pos[i1] + pos[i2]) / 3.0;
    final cy = a.y + (pos[i0 + 1] + pos[i1 + 1] + pos[i2 + 1]) / 3.0;
    final cz = a.z + (pos[i0 + 2] + pos[i1 + 2] + pos[i2 + 2]) / 3.0;
    final dir = Vector3(cx, cy, cz).normalized;
    var covered = false;
    for (final m in masked) {
      if (m.contains(dir)) {
        covered = true;
        break;
      }
    }
    if (covered) continue;
    out[w] = src[t];
    out[w + 1] = src[t + 1];
    out[w + 2] = src[t + 2];
    w += 3;
    if (cell.chunk.contains(dir)) interior++;
  }
  return (indices: Uint32List.sublistView(out, 0, w), interiorRemaining: interior);
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
