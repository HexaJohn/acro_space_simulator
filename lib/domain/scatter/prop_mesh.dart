// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import '../shared/vector3.dart';

/// An axis-aligned bounding box in prop-local metres.
class PropBounds {
  const PropBounds(this.min, this.max);

  /// The empty box — `min` above `max` so the first [expand] replaces both.
  static const PropBounds empty = PropBounds(
    Vector3(double.infinity, double.infinity, double.infinity),
    Vector3(-double.infinity, -double.infinity, -double.infinity),
  );

  final Vector3 min;
  final Vector3 max;

  bool get isEmpty => min.x > max.x;

  Vector3 get size => isEmpty ? Vector3.zero : max - min;
  Vector3 get centre => isEmpty ? Vector3.zero : (min + max) * 0.5;

  /// Height along the growth axis (+Z), which is what LOD/imposter sizing uses.
  double get heightM => isEmpty ? 0.0 : max.z - min.z;

  /// Radius of the tightest vertical cylinder around the prop (m) — the
  /// horizontal half-extent, used for imposter card width and cull radius.
  double get radiusM {
    if (isEmpty) return 0.0;
    final rx = (max.x - min.x) * 0.5, ry = (max.y - min.y) * 0.5;
    return rx > ry ? rx : ry;
  }

  /// The box containing both this and [other]; either may be [empty].
  PropBounds union(PropBounds other) {
    if (isEmpty) return other;
    if (other.isEmpty) return this;
    return PropBounds(
      Vector3(
        math.min(min.x, other.min.x),
        math.min(min.y, other.min.y),
        math.min(min.z, other.min.z),
      ),
      Vector3(
        math.max(max.x, other.max.x),
        math.max(max.y, other.max.y),
        math.max(max.z, other.max.z),
      ),
    );
  }
}

/// A generated prop's triangle mesh, in **prop-local metres, Z-up**, with the
/// origin at the base (so a prop drops straight onto the ground by placing its
/// origin at the surface point).
///
/// Structure-of-arrays in exactly the layout `MeshGeometry.fromArrays` takes,
/// so the infrastructure adapter is a straight handoff with no repacking. Pure
/// data + pure Dart: isolate-safe and testable without a GPU.
class PropMesh {
  PropMesh({
    required this.positions,
    required this.normals,
    required this.texCoords,
    required this.indices,
  });

  /// Three floats per vertex.
  final Float32List positions;

  /// Three floats per vertex, unit length.
  final Float32List normals;

  /// Two floats per vertex.
  final Float32List texCoords;

  /// Triangle list.
  final Uint32List indices;

  static final PropMesh empty = PropMesh(
    positions: Float32List(0),
    normals: Float32List(0),
    texCoords: Float32List(0),
    indices: Uint32List(0),
  );

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;
  bool get isEmpty => indices.isEmpty;

  PropBounds get bounds {
    if (positions.isEmpty) return PropBounds.empty;
    var nx = positions[0], ny = positions[1], nz = positions[2];
    var xx = nx, xy = ny, xz = nz;
    for (var i = 3; i < positions.length; i += 3) {
      final x = positions[i], y = positions[i + 1], z = positions[i + 2];
      if (x < nx) nx = x;
      if (y < ny) ny = y;
      if (z < nz) nz = z;
      if (x > xx) xx = x;
      if (y > xy) xy = y;
      if (z > xz) xz = z;
    }
    return PropBounds(Vector3(nx, ny, nz), Vector3(xx, xy, xz));
  }

  /// Wavefront OBJ text, for eyeballing a dump in any 3D viewer (matches
  /// [SurfaceMesh.toObj]'s role for the terrain mesher).
  String toObj() {
    final b = StringBuffer();
    for (var i = 0; i < positions.length; i += 3) {
      b.writeln('v ${positions[i]} ${positions[i + 1]} ${positions[i + 2]}');
    }
    for (var i = 0; i < texCoords.length; i += 2) {
      b.writeln('vt ${texCoords[i]} ${texCoords[i + 1]}');
    }
    for (var i = 0; i < normals.length; i += 3) {
      b.writeln('vn ${normals[i]} ${normals[i + 1]} ${normals[i + 2]}');
    }
    for (var i = 0; i < indices.length; i += 3) {
      final a = indices[i] + 1, c = indices[i + 1] + 1, d = indices[i + 2] + 1;
      b.writeln('f $a/$a/$a $c/$c/$c $d/$d/$d');
    }
    return b.toString();
  }
}
