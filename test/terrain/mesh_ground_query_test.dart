// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/mesh_ground_query.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

/// `radialHitOnCell` reads the ground off a meshed cell — the ground as
/// DRAWN. Pinned: it lands on the mesh where the mesh is (within a voxel of
/// the field the mesh approximates, and closer than that inside the cell),
/// and it says so when the ray is outside the cell.
void main() {
  final field = TerrainField(
    radius: 1.7374e6,
    amplitude: 4000,
    featureScale: 60000,
    seed: 0x11A00,
  );
  final dir = const Vector3(0.3, 0.4, 0.87).normalized;

  test('the radial through a meshed cell hits within a voxel of the field',
      () {
    for (final level in [10, 14, 16]) {
      final key = chunkAt(dir, level);
      final cell = meshTerrainCell(field, key, resolution: 16);
      expect(cell.isEmpty, isFalse);
      final voxel = key.circumradiusM(field.radius) * 2 / 16;
      final hit = radialHitOnCell(cell, dir);
      expect(hit, isNotNull, reason: 'level $level: the ray missed its cell');
      final analytic = field.groundRadiusAt(dir.x, dir.y, dir.z);
      expect((hit! - analytic).abs(), lessThan(voxel),
          reason: 'level $level: mesh hit $hit vs field $analytic, '
              'voxel $voxel');
    }
  });

  test('a ray outside the cell reports no hit', () {
    final key = chunkAt(dir, 14);
    final cell = meshTerrainCell(field, key, resolution: 16);
    // A direction a few cells over: not this chunk's ground.
    final far = const Vector3(0.3, 0.43, 0.87).normalized;
    expect(chunkAt(far, 14) == key, isFalse);
    expect(radialHitOnCell(cell, far), isNull);
  });
}
