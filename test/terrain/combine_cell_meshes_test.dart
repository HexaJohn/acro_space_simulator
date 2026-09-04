// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

/// The geometry half of terrain draw-call batching: the combined buffer must
/// put every member's vertices exactly where that member's own node would
/// have (same body frame, re-anchored by pure translation), with indices
/// rebased onto the concatenated vertex list.
void main() {
  TerrainField moon() => TerrainField(
        radius: 1.7371e6,
        amplitude: 2000,
        featureScale: 60000,
        seed: 7,
        octaves: 5,
      );

  test('a combined mesh is each member, translated to the group anchor', () {
    final field = moon();
    final dir = Vector3(0.3, 0.2, 0.93).normalized;
    final a = chunkAt(dir, 8);
    // A neighbour: same parent, next cell over.
    final b = ChunkKey(a.face, a.level, a.u + 1, a.v);
    final ca = meshTerrainCell(field, a, resolution: 8, skirtVoxels: 1);
    final cb = meshTerrainCell(field, b, resolution: 8, skirtVoxels: 1);
    expect(ca.isEmpty, isFalse);
    expect(cb.isEmpty, isFalse);

    final anchor = ca.anchorBF;
    final combined = combineCellMeshes([ca, cb], anchor);

    expect(combined.vertexCount, ca.mesh.vertexCount + cb.mesh.vertexCount);
    expect(combined.triangleCount,
        ca.mesh.triangleCount + cb.mesh.triangleCount);

    // Member 0 anchors AT the group anchor: verbatim copy.
    for (var i = 0; i < ca.mesh.positions.length; i++) {
      expect(combined.positions[i], ca.mesh.positions[i]);
      expect(combined.normals[i], ca.mesh.normals[i]);
    }
    // Member 1: every vertex moved by exactly its anchor delta.
    final d = cb.anchorBF - anchor;
    final base = ca.mesh.positions.length;
    for (var i = 0; i < cb.mesh.positions.length; i += 3) {
      expect(combined.positions[base + i],
          closeTo(cb.mesh.positions[i] + d.x, 1e-2));
      expect(combined.positions[base + i + 1],
          closeTo(cb.mesh.positions[i + 1] + d.y, 1e-2));
      expect(combined.positions[base + i + 2],
          closeTo(cb.mesh.positions[i + 2] + d.z, 1e-2));
    }
    // Member 1's indices rebased past member 0's vertices, all in range.
    final vbase = ca.mesh.vertexCount;
    for (var i = 0; i < cb.mesh.indices.length; i++) {
      final idx = combined.indices[ca.mesh.indices.length + i];
      expect(idx, cb.mesh.indices[i] + vbase);
      expect(idx, lessThan(combined.vertexCount));
    }
  });

  test('an empty member list combines to an empty mesh', () {
    final combined = combineCellMeshes(const [], Vector3.zero);
    expect(combined.isEmpty, isTrue);
    expect(combined.vertexCount, 0);
  });
}
