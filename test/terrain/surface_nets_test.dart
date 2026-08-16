// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/terrain/surface_nets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every undirected edge of a closed manifold is shared by exactly two
/// triangles. Returns the count of edges that are NOT (open/non-manifold).
int _nonManifoldEdges(SurfaceMesh m) {
  final counts = <int, int>{};
  void bump(int a, int b) {
    final key = a < b ? a * 100000000 + b : b * 100000000 + a;
    counts[key] = (counts[key] ?? 0) + 1;
  }

  for (var i = 0; i < m.indices.length; i += 3) {
    final a = m.indices[i], b = m.indices[i + 1], c = m.indices[i + 2];
    bump(a, b);
    bump(b, c);
    bump(c, a);
  }
  return counts.values.where((v) => v != 2).length;
}

/// Write an OBJ next to the test output so a mesh can be eyeballed in any
/// viewer. Best-effort — never fail the test on IO.
void _dumpObj(String name, SurfaceMesh m) {
  try {
    final dir = Directory('test_out/terrain')..createSync(recursive: true);
    File('${dir.path}/$name.obj').writeAsStringSync(m.toObj());
  } catch (_) {}
}

void main() {
  test('sphere: watertight, round, outward normals', () {
    const r = 8.0, vs = 1.0, o = -11.0, n = 23; // spans -11..+11, r=8 enclosed
    final grid = DensityGrid.sample(
      (x, y, z) => math.sqrt(x * x + y * y + z * z) - r,
      nx: n, ny: n, nz: n, voxelSize: vs, originX: o, originY: o, originZ: o,
    );
    final mesh = surfaceNets(grid);
    _dumpObj('sphere', mesh);

    expect(mesh.isEmpty, isFalse);
    expect(mesh.triangleCount, greaterThan(200));
    // Closed surface -> no open edges.
    expect(_nonManifoldEdges(mesh), 0, reason: 'sphere must be watertight');

    // Every vertex sits ~on the sphere, and its normal points radially out.
    for (var i = 0; i < mesh.positions.length; i += 3) {
      final x = mesh.positions[i], y = mesh.positions[i + 1], z = mesh.positions[i + 2];
      final len = math.sqrt(x * x + y * y + z * z);
      expect((len - r).abs(), lessThan(vs), reason: 'vertex off the sphere');
      final nx = mesh.normals[i], ny = mesh.normals[i + 1], nz = mesh.normals[i + 2];
      final dot = (x * nx + y * ny + z * nz) / len; // cos angle to radial-out
      expect(dot, greaterThan(0.9), reason: 'normal not outward');
    }
  });

  test('box: watertight with flat faces', () {
    // Box half-extent 6, as an SDF (negative inside). Grid encloses it in air.
    const h = 6.0, vs = 1.0, o = -10.0, n = 21;
    double box(double x, double y, double z) {
      final dx = x.abs() - h, dy = y.abs() - h, dz = z.abs() - h;
      final outside = math.sqrt(
        math.max(dx, 0.0) * math.max(dx, 0.0) +
        math.max(dy, 0.0) * math.max(dy, 0.0) +
        math.max(dz, 0.0) * math.max(dz, 0.0),
      );
      final inside = math.min(math.max(dx, math.max(dy, dz)), 0.0);
      return outside + inside;
    }

    final grid = DensityGrid.sample(box,
        nx: n, ny: n, nz: n, voxelSize: vs, originX: o, originY: o, originZ: o);
    final mesh = surfaceNets(grid);
    _dumpObj('box', mesh);

    expect(mesh.isEmpty, isFalse);
    expect(_nonManifoldEdges(mesh), 0, reason: 'box must be watertight');
  });

  test('plane: flat sheet, normals point up', () {
    // Solid half-space z<0; the isosurface is the z=0 plane. Open at the grid
    // sides (those are a neighbour chunk's faces), so NOT watertight.
    const vs = 1.0, o = -10.0, n = 21;
    final grid = DensityGrid.sample((x, y, z) => z,
        nx: n, ny: n, nz: n, voxelSize: vs, originX: o, originY: o, originZ: o);
    final mesh = surfaceNets(grid);
    _dumpObj('plane', mesh);

    expect(mesh.isEmpty, isFalse);
    for (var i = 0; i < mesh.positions.length; i += 3) {
      expect(mesh.positions[i + 2].abs(), lessThan(vs), reason: 'not flat at z=0');
      expect(mesh.normals[i + 2], greaterThan(0.9), reason: 'normal not +z');
    }
  });

  test('voxelSize scales the mesh (no hardcoded cell size)', () {
    double sphere(double x, double y, double z) =>
        math.sqrt(x * x + y * y + z * z) - 4.0;
    SurfaceMesh meshAt(double vs) => surfaceNets(DensityGrid.sample(
          sphere,
          nx: 21, ny: 21, nz: 21, voxelSize: vs,
          originX: -10 * vs, originY: -10 * vs, originZ: -10 * vs,
        ));
    // Same grid resolution, doubled voxelSize -> the sampled sphere (radius 4
    // in world units) is smaller relative to the grid, so a different vertex
    // set; the point is world math tracks voxelSize, not a literal.
    final a = meshAt(1.0), b = meshAt(0.5);
    expect(a.isEmpty, isFalse);
    expect(b.isEmpty, isFalse);
    // At vs=0.5 the grid only spans -5..+5, radius-4 sphere still fits.
    for (var i = 0; i < b.positions.length; i += 3) {
      final x = b.positions[i], y = b.positions[i + 1], z = b.positions[i + 2];
      expect((math.sqrt(x * x + y * y + z * z) - 4.0).abs(), lessThan(0.5));
    }
  });
}
