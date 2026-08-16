// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The geometric LOD mask: a coarse chunk's triangles inside a refined child's
// footprint are filtered out of its index buffer, so coarse never draws under
// fine, and interiorRemaining hitting zero is the signal to drop the chunk.

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final field = TerrainField(
    radius: 1.7374e6,
    amplitude: 4000,
    featureScale: 60000,
    seed: 0x11A00,
  );
  final parent = chunkAt(const Vector3(0.3, 0.4, 0.87).normalized, 6);
  final cell = meshTerrainCell(field, parent, resolution: 16);

  test('masking one child removes only that quadrant', () {
    final child = parent.children.first;
    final full = cell.mesh.indices.length;
    final r = maskCellIndices(cell, {child});
    expect(r.indices.length, lessThan(full));
    expect(r.indices.length, greaterThan(full ~/ 2),
        reason: 'one quadrant plus boundary raggedness, not half the mesh');
    expect(r.interiorRemaining, greaterThan(0));
    // No surviving triangle's centroid may lie inside the masked child.
    final pos = cell.mesh.positions;
    for (var t = 0; t < r.indices.length; t += 3) {
      final i0 = r.indices[t] * 3,
          i1 = r.indices[t + 1] * 3,
          i2 = r.indices[t + 2] * 3;
      final dir = Vector3(
        cell.anchorBF.x + (pos[i0] + pos[i1] + pos[i2]) / 3,
        cell.anchorBF.y + (pos[i0 + 1] + pos[i1 + 1] + pos[i2 + 1]) / 3,
        cell.anchorBF.z + (pos[i0 + 2] + pos[i1 + 2] + pos[i2 + 2]) / 3,
      ).normalized;
      expect(child.contains(dir), isFalse);
    }
  });

  test('masking all four children empties the interior', () {
    final r = maskCellIndices(cell, parent.children.toSet());
    expect(r.interiorRemaining, 0,
        reason: 'fully refined: nothing of the parent surface should remain');
  });

  test('masking deeper descendants also counts', () {
    // One child refined a level further: its four children together must
    // mask the same region the child itself would.
    final child = parent.children.first;
    final viaChild = maskCellIndices(cell, {child});
    final viaGrandchildren = maskCellIndices(cell, child.children.toSet());
    // Same quadrant covered either way; centroid raggedness allows a small
    // difference at the internal boundaries.
    final diff =
        (viaChild.indices.length - viaGrandchildren.indices.length).abs();
    expect(diff, lessThanOrEqualTo(cell.mesh.indices.length ~/ 10));
  });

  test('empty mask is the identity', () {
    final r = maskCellIndices(cell, const {});
    expect(r.indices, cell.mesh.indices);
    expect(r.interiorRemaining, greaterThan(0));
  });
}
