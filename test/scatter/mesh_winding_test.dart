// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/scatter/prop_catalog.dart';
import 'package:acro_space_simulator/domain/scatter/prop_mesh.dart';
import 'package:acro_space_simulator/domain/scatter/prop_model.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

/// Triangle winding is the one property of this geometry that unit tests can
/// pin down and eyeballing cannot: an inside-out mesh looks *plausible* in a
/// screenshot — a trunk still reads as a trunk — right up until you notice you
/// are seeing its far wall through its near one. It cost a long debugging
/// session once; these tests exist so it costs nothing the next time.
///
/// The engine's front face is the OPPOSITE of the right-hand rule (see
/// [MeshBuilder.triangle]), so a correctly wound surface has every triangle's
/// right-hand normal pointing AWAY from the visible side.
void main() {
  /// Fraction of triangles whose right-hand normal agrees with the average of
  /// their own vertex normals.
  double agreement(PropMesh mesh) {
    if (mesh.isEmpty) return 1.0;
    var agree = 0, total = 0;
    for (var i = 0; i < mesh.indices.length; i += 3) {
      final ia = mesh.indices[i], ib = mesh.indices[i + 1];
      final ic = mesh.indices[i + 2];
      Vector3 pos(int v) => Vector3(mesh.positions[v * 3],
          mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2]);
      Vector3 nrm(int v) => Vector3(mesh.normals[v * 3],
          mesh.normals[v * 3 + 1], mesh.normals[v * 3 + 2]);
      final a = pos(ia), b = pos(ib), c = pos(ic);
      final rh = (b - a).cross(c - a);
      if (rh.lengthSquared < 1e-18) continue; // degenerate; carries no winding
      final shading = nrm(ia) + nrm(ib) + nrm(ic);
      if (shading.lengthSquared < 1e-18) continue;
      total++;
      if (rh.dot(shading) > 0) agree++;
    }
    return total == 0 ? 1.0 : agree / total;
  }

  test('a tube is wound so the engine shows its OUTSIDE', () {
    final b = MeshBuilder()
      ..tube(
        [const Vector3(0, 0, 0), const Vector3(0, 0, 2)],
        [0.3, 0.2],
        sides: 8,
        capEnd: true,
      );
    // Every triangle's right-hand normal must oppose its shading normal, which
    // is the engine's front-facing order. Agreement would mean the trunk is
    // inside out and renders hollow.
    expect(agreement(b.build()), 0.0);
  });

  test('an icosphere is wound so the engine shows its OUTSIDE', () {
    for (final faceted in [false, true]) {
      final b = MeshBuilder()..icosphere(radius: 1.0, subdivisions: 2, faceted: faceted);
      expect(agreement(b.build()), 0.0, reason: 'faceted=$faceted');
    }
  });

  /// Net facing of each triangle along [axis]: how many point with it versus
  /// against it, judged by the vertex normals rather than the winding.
  (int, int) facingSplit(PropMesh mesh, Vector3 axis) {
    var withAxis = 0, against = 0;
    for (var i = 0; i < mesh.indices.length; i += 3) {
      var d = 0.0;
      for (var k = 0; k < 3; k++) {
        final v = mesh.indices[i + k];
        d += Vector3(mesh.normals[v * 3], mesh.normals[v * 3 + 1],
                mesh.normals[v * 3 + 2])
            .dot(axis);
      }
      if (d > 0) {
        withAxis++;
      } else if (d < 0) {
        against++;
      }
    }
    return (withAxis, against);
  }

  test('a two-sided card is two self-consistent faces back to back', () {
    final mesh = (MeshBuilder()..card(width: 1, height: 1)).build();
    expect(mesh.triangleCount, 4, reason: 'two quads, one per side');
    // BOTH copies are individually wound for the engine — being two-sided is
    // not a winding inconsistency, it is two correct faces pointing opposite
    // ways. (An earlier version of this test wrongly expected half the mesh to
    // be "wrong", which would have passed on genuinely broken geometry.)
    expect(agreement(mesh), 0.0);
    expect(facingSplit(mesh, const Vector3(0, 1, 0)), (2, 2),
        reason: 'the two faces must point opposite ways in equal measure');
  });

  test('a one-sided card is wound for the engine', () {
    final b = MeshBuilder()..card(width: 1, height: 1, twoSided: false);
    expect(agreement(b.build()), 0.0);
  });

  test('every solid prop surface is wound consistently outward', () {
    for (final kind in PropKind.values) {
      final solid = buildProp(kind, seed: 6)[PropLod.lod0].solid;
      if (solid.isEmpty) continue;
      expect(agreement(solid), 0.0,
          reason: '$kind has inside-out solid geometry');
    }
  });

  test('foliage is wound outward and emitted in two-sided pairs', () {
    for (final kind in PropKind.values) {
      final foliage = buildProp(kind, seed: 6)[PropLod.lod0].foliage;
      if (foliage.isEmpty) continue;
      expect(agreement(foliage), 0.0,
          reason: '$kind foliage is wound inside out');
      // Every card is emitted twice, so the triangle count must be even and
      // the mesh must carry both facings. With back-face culling the viewer
      // then always gets the copy whose normal points at them — which is what
      // stops leaf clumps shading inside out and blowing out to flat grey.
      expect(foliage.triangleCount.isEven, isTrue,
          reason: '$kind foliage is not emitted in pairs');
      final (a, b) = facingSplit(foliage, const Vector3(0, 0, 1));
      expect(a, greaterThan(0), reason: '$kind foliage faces only one way');
      expect(b, greaterThan(0), reason: '$kind foliage faces only one way');
    }
  });
}
