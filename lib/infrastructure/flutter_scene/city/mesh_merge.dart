// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;

import '../../../domain/scatter/prop_mesh.dart';

/// Concatenates transformed copies of [PropMesh]es into one mesh.
///
/// This is the skyline path. A colony seen from its framing distance is
/// hundreds of block-tier silhouettes, and drawing them as instanced
/// archetypes cost a draw per archetype per material — some fifteen native
/// binds on the UI thread, repeated for the colour pass and every shadow
/// cascade — plus a BVH item and an instance repack per pass: 244 of a
/// 273-draw city. Baked into one mesh per material they are two draws.
///
/// Typed buffers with doubling capacity, not `List<double>`: a whole colony is
/// a few hundred thousand vertices, and boxing every coordinate would turn a
/// rebuild into a garbage-collection event.
class MergedMeshSink {
  MergedMeshSink({int vertexCapacity = 4096})
      : _pos = Float32List(math.max(1, vertexCapacity) * 3),
        _nrm = Float32List(math.max(1, vertexCapacity) * 3),
        _uv = Float32List(math.max(1, vertexCapacity) * 2),
        _idx = Uint32List(math.max(1, vertexCapacity) * 2);

  Float32List _pos, _nrm, _uv;
  Uint32List _idx;
  int _vtx = 0, _ind = 0;

  int get vertexCount => _vtx;
  int get triangleCount => _ind ~/ 3;
  bool get isEmpty => _ind == 0;

  /// Append [mesh] with every vertex taken through [transform]: positions by
  /// the full matrix, normals by its rotation and re-normalised, so a
  /// uniformly scaled transform (the metres-to-scene instance matrix) is
  /// fine. Indices are offset past the vertices already held.
  void append(PropMesh mesh, vm.Matrix4 transform) {
    if (mesh.isEmpty) return;
    final n = mesh.vertexCount;
    _reserve(n, mesh.indices.length);
    // Column-major: element (row r, column c) sits at c * 4 + r.
    final s = transform.storage;
    final m0 = s[0], m1 = s[1], m2 = s[2];
    final m4 = s[4], m5 = s[5], m6 = s[6];
    final m8 = s[8], m9 = s[9], m10 = s[10];
    final tx = s[12], ty = s[13], tz = s[14];
    final p = mesh.positions, q = mesh.normals;
    final base = _vtx;
    var o = base * 3;
    for (var i = 0; i < n * 3; i += 3, o += 3) {
      final x = p[i], y = p[i + 1], z = p[i + 2];
      _pos[o] = m0 * x + m4 * y + m8 * z + tx;
      _pos[o + 1] = m1 * x + m5 * y + m9 * z + ty;
      _pos[o + 2] = m2 * x + m6 * y + m10 * z + tz;
      final nx = q[i], ny = q[i + 1], nz = q[i + 2];
      var rx = m0 * nx + m4 * ny + m8 * nz;
      var ry = m1 * nx + m5 * ny + m9 * nz;
      var rz = m2 * nx + m6 * ny + m10 * nz;
      final len = math.sqrt(rx * rx + ry * ry + rz * rz);
      if (len > 0) {
        rx /= len;
        ry /= len;
        rz /= len;
      }
      _nrm[o] = rx;
      _nrm[o + 1] = ry;
      _nrm[o + 2] = rz;
    }
    final t = mesh.texCoords;
    final uvCount = math.min(t.length, n * 2);
    _uv.setRange(base * 2, base * 2 + uvCount, t);
    final idx = mesh.indices;
    for (var j = 0; j < idx.length; j++) {
      _idx[_ind + j] = base + idx[j];
    }
    _ind += idx.length;
    _vtx += n;
  }

  /// Append [mesh] as it is: no transform, a straight copy of every stream
  /// with the indices offset past the vertices already held.
  ///
  /// This is the material-merge path. A tile's road, lamp, prop, curb and
  /// lot builders all emit in the tile's own scene space already, so
  /// gathering them into one geometry per material needs no matrix at all
  /// — and a near tile has a few hundred thousand such vertices, which
  /// [append]'s per-vertex matrix multiply and normal re-normalise would
  /// spend for nothing. Three `setRange`s and one index offset loop instead.
  void appendMesh(PropMesh mesh) {
    if (mesh.isEmpty) return;
    final n = mesh.vertexCount;
    _reserve(n, mesh.indices.length);
    final base = _vtx;
    _pos.setRange(base * 3, base * 3 + n * 3, mesh.positions);
    _nrm.setRange(base * 3, base * 3 + n * 3, mesh.normals);
    final t = mesh.texCoords;
    final uvCount = math.min(t.length, n * 2);
    _uv.setRange(base * 2, base * 2 + uvCount, t);
    final idx = mesh.indices;
    for (var j = 0; j < idx.length; j++) {
      _idx[_ind + j] = base + idx[j];
    }
    _ind += idx.length;
    _vtx += n;
  }

  void _reserve(int vertices, int indices) {
    final needV = _vtx + vertices;
    if (needV * 3 > _pos.length) {
      var cap = _pos.length ~/ 3;
      while (cap < needV) {
        cap *= 2;
      }
      _pos = _grow(_pos, cap * 3);
      _nrm = _grow(_nrm, cap * 3);
      _uv = _grow(_uv, cap * 2);
    }
    final needI = _ind + indices;
    if (needI > _idx.length) {
      var cap = _idx.length;
      while (cap < needI) {
        cap *= 2;
      }
      _idx = Uint32List(cap)..setRange(0, _ind, _idx);
    }
  }

  static Float32List _grow(Float32List old, int length) =>
      Float32List(length)..setRange(0, old.length, old);

  /// The merged mesh, as views over the sink's buffers: build once, at the
  /// end, and do not append afterwards.
  PropMesh build() => PropMesh(
        positions: Float32List.sublistView(_pos, 0, _vtx * 3),
        normals: Float32List.sublistView(_nrm, 0, _vtx * 3),
        texCoords: Float32List.sublistView(_uv, 0, _vtx * 2),
        indices: Uint32List.sublistView(_idx, 0, _ind),
      );
}
