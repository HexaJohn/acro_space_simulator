// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/scatter/prop_mesh.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

/// The OLD [MeshBuilder] storage: boxed growable lists appended per vertex and
/// converted to typed arrays at the end. Positions and normals are handed in
/// already transformed — the tests take them from the builder's own frame
/// queries — so the reference is exactly the representation the typed
/// buffers replaced, and the two must agree element for element.
class _Reference {
  final positions = <double>[];
  final normals = <double>[];
  final texCoords = <double>[];
  final indices = <int>[];

  int vertex(Vector3 p, Vector3 n, double u, double v) {
    positions.addAll([p.x, p.y, p.z]);
    normals.addAll([n.x, n.y, n.z]);
    texCoords.addAll([u, v]);
    return (positions.length ~/ 3) - 1;
  }

  void triangle(int a, int b, int c) => indices.addAll([a, c, b]);

  PropMesh build() => PropMesh(
        positions: Float32List.fromList(positions),
        normals: Float32List.fromList(normals),
        texCoords: Float32List.fromList(texCoords),
        indices: Uint32List.fromList(indices),
      );
}

/// [MeshBuilder] keeps its vertices in growable typed arrays that double as
/// they fill. The failure modes of that are all silent — a doubling that drops
/// the tail of the used prefix, an off-by-one at the boundary, a `build()`
/// that hands out the spare capacity as if it were geometry — and none of them
/// would show in a screenshot as anything but a slightly wrong prop. So every
/// test here drives the builder well past several doublings and compares it
/// with the boxed [_Reference].
void main() {
  void expectSame(PropMesh got, PropMesh want) {
    expect(got.vertexCount, want.vertexCount);
    expect(got.triangleCount, want.triangleCount);
    // Exact-length arrays: the spare capacity must never leak out.
    expect(got.positions.length, got.vertexCount * 3);
    expect(got.normals.length, got.vertexCount * 3);
    expect(got.texCoords.length, got.vertexCount * 2);
    expect(got.indices.length, got.triangleCount * 3);
    // Both sides are float32 by now, so equality is exact, not approximate.
    expect(got.positions, orderedEquals(want.positions));
    expect(got.normals, orderedEquals(want.normals));
    expect(got.texCoords, orderedEquals(want.texCoords));
    expect(got.indices, orderedEquals(want.indices));
  }

  test('typed storage matches the boxed reference across many doublings', () {
    final b = MeshBuilder();
    final ref = _Reference();
    final rng = math.Random(7);
    // Well past several doublings of the default reservation, with the turtle
    // wandering so the frame transform is part of what is compared.
    const strips = 400;
    const perStrip = 64;
    for (var s = 0; s < strips; s++) {
      b.push();
      b.move(Vector3(rng.nextDouble() * 10, rng.nextDouble() * 10, 0));
      b.yaw(rng.nextDouble() * math.pi);
      b.pitch((rng.nextDouble() - 0.5) * 0.4);
      b.scaleBy(0.5 + rng.nextDouble());
      int? prevL, prevR;
      for (var i = 0; i < perStrip; i++) {
        final pl = Vector3(-0.1 - i * 0.001, 0, i * 0.05);
        final pr = Vector3(0.1 + i * 0.001, 0, i * 0.05);
        final n = Vector3(rng.nextDouble() - 0.5, 1, rng.nextDouble() - 0.5)
            .normalized;
        final v = i / (perStrip - 1);
        final l = b.vertex(pl, n, 0, v);
        final r = b.vertex(pr, n, 1, v);
        // The reference sees the same transformed values through the public
        // frame queries, which is what the builder stores.
        final rl = ref.vertex(b.toMesh(pl), b.orientation.rotate(n), 0, v);
        final rr = ref.vertex(b.toMesh(pr), b.orientation.rotate(n), 1, v);
        expect(l, rl);
        expect(r, rr);
        if (prevL != null && prevR != null) {
          b.quad(prevL, prevR, r, l);
          ref.triangle(prevL, prevR, r);
          ref.triangle(prevL, r, l);
        }
        prevL = l;
        prevR = r;
        b.forward(0.01);
      }
      b.pop();
    }
    expect(b.vertexCount, strips * perStrip * 2);
    // 51 200 vertices is eight doublings past the 128-vertex default.
    expect(b.vertexCount, greaterThan(128 * 128));
    expectSame(b.build(), ref.build());
  });

  test('the initial reservation does not change the mesh', () {
    // A capacity of one vertex hits a doubling on almost every emission; a
    // generous one never grows. Same primitives, so the same bytes.
    final spine = [
      for (var i = 0; i < 40; i++) Vector3(math.sin(i * 0.1), 0, i * 0.25),
    ];
    final radii = [for (var i = 0; i < 40; i++) 0.5 - i * 0.01];
    PropMesh make(int capacity) => (MeshBuilder(vertexCapacity: capacity)
          ..tube(spine, radii, sides: 12, capEnd: true)
          ..icosphere(radius: 1.0, subdivisions: 3)
          ..crossCards(width: 2, height: 3))
        .build();
    final tiny = make(1);
    final big = make(1 << 16);
    expect(tiny.vertexCount, greaterThan(1000));
    expectSame(tiny, big);
  });

  test('build() copies, so later emission cannot reach an earlier mesh', () {
    final b = MeshBuilder(vertexCapacity: 2)
      ..vertex(const Vector3(1, 2, 3), Vector3.unitZ, 0, 0)
      ..vertex(const Vector3(4, 5, 6), Vector3.unitZ, 1, 0)
      ..vertex(const Vector3(7, 8, 9), Vector3.unitZ, 1, 1)
      ..triangle(0, 1, 2);
    final first = b.build();
    b
      ..vertex(const Vector3(-1, -2, -3), Vector3.unitX, 0, 1)
      ..triangle(0, 2, 3);
    final second = b.build();
    expect(first.vertexCount, 3);
    expect(first.triangleCount, 1);
    expect(first.positions, orderedEquals([1, 2, 3, 4, 5, 6, 7, 8, 9]));
    // Engine winding: [a, c, b], as the old boxed builder emitted it.
    expect(first.indices, orderedEquals([0, 2, 1]));
    expect(second.vertexCount, 4);
    expect(second.triangleCount, 2);
    expect(second.indices, orderedEquals([0, 2, 1, 0, 3, 2]));
  });

  test('an empty builder builds the empty mesh', () {
    final m = MeshBuilder().build();
    expect(m.isEmpty, isTrue);
    expect(m.positions, isEmpty);
    expect(m.normals, isEmpty);
    expect(m.texCoords, isEmpty);
    expect(m.indices, isEmpty);
  });

  test('flat triangles and the turtle stack still agree with the reference',
      () {
    final b = MeshBuilder(vertexCapacity: 4);
    final ref = _Reference();
    for (var i = 0; i < 300; i++) {
      b.push();
      b.turn(Quaternion.axisAngle(Vector3.unitZ, i * 0.05));
      b.forward(i * 0.01);
      final a = Vector3(i * 0.1, 0, 0);
      final c = Vector3(i * 0.1 + 1, 0, 0);
      final d = Vector3(i * 0.1, 1, 0);
      b.flatTriangle(a, c, d, uScale: 0.5);
      final n = b.orientation.rotate(Vector3.unitZ);
      final ia = ref.vertex(b.toMesh(a), n, a.x * 0.5, a.y * 0.5);
      final ic = ref.vertex(b.toMesh(c), n, c.x * 0.5, c.y * 0.5);
      final id = ref.vertex(b.toMesh(d), n, d.x * 0.5, d.y * 0.5);
      ref.triangle(ia, ic, id);
      b.pop();
    }
    expectSame(b.build(), ref.build());
  });
}
