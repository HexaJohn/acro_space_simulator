// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../shared/vector3.dart';
import 'cell_mesher.dart';

/// The outermost radius at which the radial through body-fixed unit [dir]
/// (origin at the body centre) meets a meshed cell's triangles, or null when
/// the ray threads a gap or misses the cell entirely.
///
/// This is the ground AS DRAWN: a vehicle resting on this radius sits on the
/// triangles on screen, whatever level the streamer has under it, where the
/// analytic field can be a voxel or more away from the mesh that approximates
/// it. Möller–Trumbore in doubles; vertices are float32 deltas off the cell's
/// body-fixed anchor, so the anchor is added once per triangle and the edge
/// vectors never see it.
double? radialHitOnCell(CellMesh cell, Vector3 dir) {
  final pos = cell.mesh.positions;
  final idx = cell.mesh.indices;
  final ax = cell.anchorBF.x, ay = cell.anchorBF.y, az = cell.anchorBF.z;
  final dx = dir.x, dy = dir.y, dz = dir.z;
  var best = double.negativeInfinity;
  for (var i = 0; i + 2 < idx.length; i += 3) {
    final i0 = idx[i] * 3, i1 = idx[i + 1] * 3, i2 = idx[i + 2] * 3;
    final p0x = pos[i0], p0y = pos[i0 + 1], p0z = pos[i0 + 2];
    final e1x = pos[i1] - p0x, e1y = pos[i1 + 1] - p0y, e1z = pos[i1 + 2] - p0z;
    final e2x = pos[i2] - p0x, e2y = pos[i2 + 1] - p0y, e2z = pos[i2 + 2] - p0z;
    // p = dir x e2
    final px = dy * e2z - dz * e2y;
    final py = dz * e2x - dx * e2z;
    final pz = dx * e2y - dy * e2x;
    final det = e1x * px + e1y * py + e1z * pz;
    if (det.abs() < 1e-12) continue;
    final inv = 1.0 / det;
    // s = origin - v0 = -(anchor + p0)
    final sx = -(ax + p0x), sy = -(ay + p0y), sz = -(az + p0z);
    final u = (sx * px + sy * py + sz * pz) * inv;
    if (u < -1e-6 || u > 1 + 1e-6) continue;
    // q = s x e1
    final qx = sy * e1z - sz * e1y;
    final qy = sz * e1x - sx * e1z;
    final qz = sx * e1y - sy * e1x;
    final v = (dx * qx + dy * qy + dz * qz) * inv;
    if (v < -1e-6 || u + v > 1 + 1e-6) continue;
    final t = (e2x * qx + e2y * qy + e2z * qz) * inv;
    if (t > best) best = t;
  }
  return best.isFinite ? best : null;
}
