/// Naive Surface Nets isosurface mesher.
///
/// Meshes ONE regular grid volume of a 3D scalar density field. Convention:
/// **negative = inside solid, positive = air, the isosurface is at 0**. Knows
/// nothing about spheres, planets, LOD, or chunk boundaries — it takes a grid
/// and returns an indexed mesh. Pure (no Flutter), so it runs unchanged inside
/// a background isolate.
///
/// The flow, per cell (a cube of 8 corner samples):
///   1. Find the cube's SIGN-CHANGE edges (endpoints straddle 0).
///   2. A cell with >=1 sign-change edge is a SURFACE CELL -> one vertex,
///      placed at the AVERAGE of the edges' zero-crossing points (linear
///      interpolation along each edge, not the cell centre).
///   3. For each of the three axis-aligned grid edges leaving a sample that
///      shows a sign change, the FOUR cells sharing that edge each contributed
///      a vertex -> join them into a quad (2 triangles), wound so the face
///      points from solid toward air.
/// Normals come from the density GRADIENT (central differences of the
/// trilinearly-sampled field), which is smoother and cheaper to get right than
/// averaging face normals.
///
/// Chunk stitching (matching seams between neighbouring grids) is NOT done
/// here. Feed a **padded** grid (a one-voxel border of samples shared with
/// neighbours) so the real surface never lands on the grid boundary; the
/// boundary faces this mesher omits are then the neighbour's to emit.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// A regular grid of density samples. [nx]/[ny]/[nz] are SAMPLE counts per
/// axis (so there are `(nx-1)*(ny-1)*(nz-1)` cells). Sample `(x,y,z)` sits at
/// world position `origin + (x,y,z) * voxelSize`.
///
/// [voxelSize] is the single source of world scale — nothing downstream may
/// hardcode a cell size.
class DensityGrid {
  DensityGrid({
    required this.samples,
    required this.nx,
    required this.ny,
    required this.nz,
    required this.voxelSize,
    this.originX = 0,
    this.originY = 0,
    this.originZ = 0,
  }) : assert(samples.length == nx * ny * nz),
       assert(voxelSize > 0);

  /// Sample a field function into a grid. `field(x,y,z)` is evaluated in WORLD
  /// coordinates at each sample point.
  factory DensityGrid.sample(
    double Function(double x, double y, double z) field, {
    required int nx,
    required int ny,
    required int nz,
    required double voxelSize,
    double originX = 0,
    double originY = 0,
    double originZ = 0,
  }) {
    final s = Float64List(nx * ny * nz);
    var i = 0;
    for (var z = 0; z < nz; z++) {
      final wz = originZ + z * voxelSize;
      for (var y = 0; y < ny; y++) {
        final wy = originY + y * voxelSize;
        for (var x = 0; x < nx; x++) {
          s[i++] = field(originX + x * voxelSize, wy, wz);
        }
      }
    }
    return DensityGrid(
      samples: s,
      nx: nx,
      ny: ny,
      nz: nz,
      voxelSize: voxelSize,
      originX: originX,
      originY: originY,
      originZ: originZ,
    );
  }

  final Float64List samples;
  final int nx, ny, nz;
  final double voxelSize;
  final double originX, originY, originZ;

  int _index(int x, int y, int z) => x + nx * (y + ny * z);

  /// Density at integer sample coordinate `(x,y,z)`.
  double at(int x, int y, int z) => samples[_index(x, y, z)];

  /// Trilinearly-interpolated density at an arbitrary WORLD position. Grid
  /// coordinates are clamped to the sampled range, so sampling just outside
  /// the volume returns the nearest face value (fine for local gradients).
  double sampleWorld(double wx, double wy, double wz) {
    final gx = ((wx - originX) / voxelSize).clamp(0.0, (nx - 1).toDouble());
    final gy = ((wy - originY) / voxelSize).clamp(0.0, (ny - 1).toDouble());
    final gz = ((wz - originZ) / voxelSize).clamp(0.0, (nz - 1).toDouble());
    final x0 = gx.floor(), y0 = gy.floor(), z0 = gz.floor();
    final x1 = math.min(x0 + 1, nx - 1);
    final y1 = math.min(y0 + 1, ny - 1);
    final z1 = math.min(z0 + 1, nz - 1);
    final fx = gx - x0, fy = gy - y0, fz = gz - z0;
    final c000 = at(x0, y0, z0), c100 = at(x1, y0, z0);
    final c010 = at(x0, y1, z0), c110 = at(x1, y1, z0);
    final c001 = at(x0, y0, z1), c101 = at(x1, y0, z1);
    final c011 = at(x0, y1, z1), c111 = at(x1, y1, z1);
    final c00 = c000 + (c100 - c000) * fx;
    final c10 = c010 + (c110 - c010) * fx;
    final c01 = c001 + (c101 - c001) * fx;
    final c11 = c011 + (c111 - c011) * fx;
    final c0 = c00 + (c10 - c00) * fy;
    final c1 = c01 + (c11 - c01) * fy;
    return c0 + (c1 - c0) * fz;
  }
}

/// How output normals were computed (exposed per spec).
enum NormalMode {
  /// Central-difference gradient of the density field (default; smoother).
  gradient,

  /// Area-weighted average of adjacent triangle face normals.
  faceAveraged,
}

/// An indexed triangle mesh. Positions/normals are packed 3 floats/vertex in
/// the grid's world frame; [indices] are triangle vertex indices.
class SurfaceMesh {
  SurfaceMesh({
    required this.positions,
    required this.normals,
    required this.indices,
    required this.normalMode,
  });

  final Float32List positions;
  final Float32List normals;
  final Uint32List indices;
  final NormalMode normalMode;

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;
  bool get isEmpty => indices.isEmpty;

  /// Wavefront OBJ text, for eyeballing a dump in any 3D viewer.
  String toObj() {
    final b = StringBuffer();
    for (var i = 0; i < positions.length; i += 3) {
      b.writeln('v ${positions[i]} ${positions[i + 1]} ${positions[i + 2]}');
    }
    for (var i = 0; i < normals.length; i += 3) {
      b.writeln('vn ${normals[i]} ${normals[i + 1]} ${normals[i + 2]}');
    }
    for (var i = 0; i < indices.length; i += 3) {
      final a = indices[i] + 1, c = indices[i + 1] + 1, d = indices[i + 2] + 1;
      b.writeln('f $a//$a $c//$c $d//$d');
    }
    return b.toString();
  }
}

// Cube corner offsets, indexed by a 3-bit code: bit0=+x, bit1=+y, bit2=+z.
const _cornerX = [0, 1, 0, 1, 0, 1, 0, 1];
const _cornerY = [0, 0, 1, 1, 0, 0, 1, 1];
const _cornerZ = [0, 0, 0, 0, 1, 1, 1, 1];

// The 12 cube edges as (cornerA, cornerB) pairs.
const _cubeEdges = <List<int>>[
  [0, 1], [0, 2], [0, 4], [1, 3], [1, 5], [2, 3],
  [2, 6], [3, 7], [4, 5], [4, 6], [5, 7], [6, 7],
];

/// Mesh [grid] with Naive Surface Nets. A sample is "solid" when its density
/// is `< isoLevel` (default 0).
SurfaceMesh surfaceNets(
  DensityGrid grid, {
  double isoLevel = 0.0,
  NormalMode normalMode = NormalMode.gradient,
}) {
  final nx = grid.nx, ny = grid.ny, nz = grid.nz;
  final vs = grid.voxelSize;
  final cx = nx - 1, cy = ny - 1, cz = nz - 1; // cell counts per axis
  if (cx <= 0 || cy <= 0 || cz <= 0) {
    return SurfaceMesh(
      positions: Float32List(0),
      normals: Float32List(0),
      indices: Uint32List(0),
      normalMode: normalMode,
    );
  }

  // Per-cell: the emitted vertex index (-1 = no surface) and the inside-mask
  // (bit p set when corner p is solid). cellIndex packs (x,y,z) x-fastest.
  final cellVertex = Int32List(cx * cy * cz)..fillRange(0, cx * cy * cz, -1);
  final cellMask = Uint8List(cx * cy * cz);
  int cellIndex(int x, int y, int z) => x + cx * (y + cy * z);

  final positions = <double>[];

  // ---- Pass 1: vertex placement ----
  // Each surface cell gets one vertex at the average of its edge crossings.
  final corner = Float64List(8);
  for (var z = 0; z < cz; z++) {
    for (var y = 0; y < cy; y++) {
      for (var x = 0; x < cx; x++) {
        var mask = 0;
        for (var p = 0; p < 8; p++) {
          final d = grid.at(x + _cornerX[p], y + _cornerY[p], z + _cornerZ[p]) -
              isoLevel;
          corner[p] = d;
          if (d < 0) mask |= 1 << p; // solid
        }
        cellMask[cellIndex(x, y, z)] = mask;
        if (mask == 0 || mask == 0xff) continue; // wholly air or wholly solid

        // Average the zero-crossing offsets over all sign-change edges.
        var ox = 0.0, oy = 0.0, oz = 0.0, count = 0;
        for (final e in _cubeEdges) {
          final a = e[0], bb = e[1];
          final da = corner[a], db = corner[bb];
          if ((da < 0) == (db < 0)) continue; // no sign change
          final t = da / (da - db); // linear crossing along the edge
          ox += _cornerX[a] + (_cornerX[bb] - _cornerX[a]) * t;
          oy += _cornerY[a] + (_cornerY[bb] - _cornerY[a]) * t;
          oz += _cornerZ[a] + (_cornerZ[bb] - _cornerZ[a]) * t;
          count++;
        }
        final inv = 1.0 / count;
        // Cell origin + averaged in-cell offset, scaled to world by voxelSize.
        final wx = grid.originX + (x + ox * inv) * vs;
        final wy = grid.originY + (y + oy * inv) * vs;
        final wz = grid.originZ + (z + oz * inv) * vs;
        cellVertex[cellIndex(x, y, z)] = positions.length ~/ 3;
        positions..add(wx)..add(wy)..add(wz);
      }
    }
  }

  // ---- Pass 2: quad/triangle emission ----
  // For each of the three axis-aligned edges leaving a cell's base corner that
  // shows a sign change, the four cells sharing that edge form a quad. Walking
  // only +x/+y/+z edges visits each shared edge once.
  final indices = <int>[];
  void quad(int a, int b, int c, int d, bool flip) {
    // Two triangles of the quad (a,b,c,d), reversed when the solid side flips
    // so the winding (and thus the generated/gradient normal) stays outward.
    if (flip) {
      indices..add(a)..add(c)..add(b)..add(a)..add(d)..add(c);
    } else {
      indices..add(a)..add(b)..add(c)..add(a)..add(c)..add(d);
    }
  }

  for (var z = 0; z < cz; z++) {
    for (var y = 0; y < cy; y++) {
      for (var x = 0; x < cx; x++) {
        final mask = cellMask[cellIndex(x, y, z)];
        if (mask == 0 || mask == 0xff) continue;
        final c0Solid = (mask & 1) != 0; // corner 0 solid?

        // Edge along +X (needs the two -1 neighbours in Y and Z).
        if (((mask >> 1) & 1) != (mask & 1) && y > 0 && z > 0) {
          quad(
            cellVertex[cellIndex(x, y, z)],
            cellVertex[cellIndex(x, y - 1, z)],
            cellVertex[cellIndex(x, y - 1, z - 1)],
            cellVertex[cellIndex(x, y, z - 1)],
            c0Solid,
          );
        }
        // Edge along +Y (needs -1 in X and Z).
        if (((mask >> 2) & 1) != (mask & 1) && x > 0 && z > 0) {
          quad(
            cellVertex[cellIndex(x, y, z)],
            cellVertex[cellIndex(x, y, z - 1)],
            cellVertex[cellIndex(x - 1, y, z - 1)],
            cellVertex[cellIndex(x - 1, y, z)],
            c0Solid,
          );
        }
        // Edge along +Z (needs -1 in X and Y).
        if (((mask >> 4) & 1) != (mask & 1) && x > 0 && y > 0) {
          quad(
            cellVertex[cellIndex(x, y, z)],
            cellVertex[cellIndex(x - 1, y, z)],
            cellVertex[cellIndex(x - 1, y - 1, z)],
            cellVertex[cellIndex(x, y - 1, z)],
            c0Solid,
          );
        }
      }
    }
  }

  final pos = Float32List.fromList(positions);
  final idx = Uint32List.fromList(indices);
  final nrm = normalMode == NormalMode.gradient
      ? _gradientNormals(grid, pos, isoLevel)
      : _faceAveragedNormals(pos, idx);
  return SurfaceMesh(
    positions: pos,
    normals: nrm,
    indices: idx,
    normalMode: normalMode,
  );
}

/// Outward normals from the density gradient: density increases from solid
/// (<0) toward air (>0), so `normalize(grad)` points out of the surface.
Float32List _gradientNormals(
    DensityGrid grid, Float32List positions, double isoLevel) {
  final n = Float32List(positions.length);
  final eps = grid.voxelSize * 0.5; // local, sub-cell
  for (var i = 0; i < positions.length; i += 3) {
    final x = positions[i], y = positions[i + 1], z = positions[i + 2];
    final gx = grid.sampleWorld(x + eps, y, z) - grid.sampleWorld(x - eps, y, z);
    final gy = grid.sampleWorld(x, y + eps, z) - grid.sampleWorld(x, y - eps, z);
    final gz = grid.sampleWorld(x, y, z + eps) - grid.sampleWorld(x, y, z - eps);
    final len = math.sqrt(gx * gx + gy * gy + gz * gz);
    if (len > 1e-12) {
      n[i] = gx / len;
      n[i + 1] = gy / len;
      n[i + 2] = gz / len;
    } else {
      n[i + 2] = 1.0; // degenerate flat region: arbitrary up
    }
  }
  return n;
}

/// Area-weighted average of adjacent face normals (alternative to gradient).
Float32List _faceAveragedNormals(Float32List positions, Uint32List indices) {
  final n = Float32List(positions.length);
  for (var t = 0; t < indices.length; t += 3) {
    final ia = indices[t] * 3, ib = indices[t + 1] * 3, ic = indices[t + 2] * 3;
    final ax = positions[ia], ay = positions[ia + 1], az = positions[ia + 2];
    final bx = positions[ib], by = positions[ib + 1], bz = positions[ib + 2];
    final cx = positions[ic], cy = positions[ic + 1], cz = positions[ic + 2];
    // Cross((b-a),(c-a)) is area-weighted (magnitude = 2*area).
    final ux = bx - ax, uy = by - ay, uz = bz - az;
    final vx = cx - ax, vy = cy - ay, vz = cz - az;
    final fx = uy * vz - uz * vy;
    final fy = uz * vx - ux * vz;
    final fz = ux * vy - uy * vx;
    for (final iv in [ia, ib, ic]) {
      n[iv] += fx;
      n[iv + 1] += fy;
      n[iv + 2] += fz;
    }
  }
  for (var i = 0; i < n.length; i += 3) {
    final len = math.sqrt(n[i] * n[i] + n[i + 1] * n[i + 1] + n[i + 2] * n[i + 2]);
    if (len > 1e-12) {
      n[i] /= len;
      n[i + 1] /= len;
      n[i + 2] /= len;
    }
  }
  return n;
}
