// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/mesh_scheduler.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A Moon-like field WITH a detail layer — the isolate has to carry the whole
  // feature list across, so the test must exercise it.
  TerrainField moon() => TerrainField(
        radius: 1.7374e6,
        amplitude: 4000,
        featureScale: 60000,
        seed: 0x11A00,
        detail: TerrainProfile.moonlike.detailFor(
          seed: 0x11A00,
          radiusM: 1.7374e6,
          amplitudeM: 4000,
          featureScaleM: 60000,
        ),
      );
  final k = chunkAt(const Vector3(0.3, 0.4, 0.87).normalized, 8);

  test('platform scheduler returns byte-identical geometry to inline meshing',
      () async {
    // On the VM the platform scheduler is the isolate one, so this is the
    // plan's determinism gate for 4c: same key -> identical mesh, regardless
    // of which thread meshed it.
    final scheduler = TerrainMeshScheduler.platform();
    final inline = meshTerrainCell(moon(), k, resolution: 16);
    final offThread =
        await scheduler.mesh(moon(), k, resolution: 16, skirtVoxels: 2.5);
    expect(offThread.mesh.positions, inline.mesh.positions);
    expect(offThread.mesh.normals, inline.mesh.normals);
    expect(offThread.mesh.indices, inline.mesh.indices);
    expect(offThread.anchorBF.x, inline.anchorBF.x);
    expect(offThread.innerRadiusM, inline.innerRadiusM);
    scheduler.dispose();
  });

  test('sync scheduler matches too', () async {
    final scheduler = SyncTerrainMeshScheduler();
    final inline = meshTerrainCell(moon(), k, resolution: 16);
    final cell =
        await scheduler.mesh(moon(), k, resolution: 16, skirtVoxels: 2.5);
    expect(cell.mesh.positions, inline.mesh.positions);
    scheduler.dispose();
  });

  test('concurrent jobs all complete and stay independent', () async {
    final scheduler = TerrainMeshScheduler.platform();
    final field = moon();
    final keys = [
      for (final d in [
        const Vector3(0.3, 0.4, 0.87),
        const Vector3(-0.6, 0.2, 0.77),
        const Vector3(0.1, -0.9, 0.4),
        const Vector3(0.7, 0.1, -0.7),
      ])
        chunkAt(d.normalized, 7),
    ];
    final cells = await Future.wait([
      for (final key in keys)
        scheduler.mesh(field, key, resolution: 12, skirtVoxels: 2.5),
    ]);
    for (var i = 0; i < keys.length; i++) {
      expect(cells[i].chunk, keys[i]);
      expect(cells[i].isEmpty, isFalse);
    }
    scheduler.dispose();
  });
}
