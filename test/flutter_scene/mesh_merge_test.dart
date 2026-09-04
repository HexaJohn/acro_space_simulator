// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/scatter/prop_mesh.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/mesh_merge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// A unit quad in the XY plane, facing +Z, one metre on a side.
PropMesh _quad() {
  final m = MeshBuilder();
  final a = m.vertex(const Vector3(0, 0, 0), Vector3.unitZ, 0, 0);
  final b = m.vertex(const Vector3(1, 0, 0), Vector3.unitZ, 1, 0);
  final c = m.vertex(const Vector3(1, 1, 0), Vector3.unitZ, 1, 1);
  final d = m.vertex(const Vector3(0, 1, 0), Vector3.unitZ, 0, 1);
  m.quad(a, b, c, d);
  return m.build();
}

void main() {
  test('copies are offset, transformed and re-indexed past each other', () {
    final quad = _quad();
    // A tiny capacity, so the append has to grow its buffers.
    final sink = MergedMeshSink(vertexCapacity: 2);
    sink.append(quad, vm.Matrix4.identity());
    // Ten metres along X, a quarter turn about X, twice the size.
    sink.append(
      quad,
      vm.Matrix4.compose(
        vm.Vector3(10, 0, 0),
        vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), math.pi / 2),
        vm.Vector3.all(2),
      ),
    );
    final out = sink.build();
    expect(out.vertexCount, 8);
    expect(out.triangleCount, 4);

    // First copy untouched.
    expect(out.positions.sublist(3, 6), [1, 0, 0]);
    // Second copy's vertex b: (1,0,0) scaled to (2,0,0), unchanged by a turn
    // about X, carried to (12,0,0).
    expect(out.positions.sublist(15, 18), [12, 0, 0]);
    // Its vertex c: (1,1,0) -> (2,2,0) -> turned about X to (2,0,2) -> +10.
    final c = out.positions.sublist(18, 21);
    expect(c[0], closeTo(12, 1e-5));
    expect(c[1], closeTo(0, 1e-5));
    expect(c[2], closeTo(2, 1e-5));

    // Normals turn with the rotation and stay unit despite the scale.
    final n = out.normals.sublist(12, 15);
    expect(n[0], closeTo(0, 1e-5));
    expect(n[1], closeTo(-1, 1e-5));
    expect(n[2], closeTo(0, 1e-5));

    // The second copy's triangles index its own vertices, not the first's.
    for (var i = 6; i < 12; i++) {
      expect(out.indices[i], inInclusiveRange(4, 7));
    }
    for (var i = 0; i < 6; i++) {
      expect(out.indices[i], inInclusiveRange(0, 3));
    }
    // Texture coordinates ride along unchanged.
    expect(out.texCoords.sublist(8, 12), [0, 0, 1, 0]);
  });

  test('an empty mesh appends nothing', () {
    final sink = MergedMeshSink();
    sink.append(PropMesh.empty, vm.Matrix4.identity());
    expect(sink.isEmpty, isTrue);
    expect(sink.build().vertexCount, 0);
  });
}
