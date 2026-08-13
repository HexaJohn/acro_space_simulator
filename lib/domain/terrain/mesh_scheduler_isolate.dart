// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITH `dart:isolate`: each mesh job runs on a
/// short-lived background isolate. See `mesh_scheduler.dart` for the seam.
///
/// `Isolate.run` per job rather than a persistent worker pool: spawn cost is a
/// fraction of a millisecond on the VM's lightweight isolates, the captured
/// state ([TerrainField] and its feature list) is a few plain objects with no
/// lookup tables, and the result's typed-data buffers are transferred, not
/// copied. A pool becomes worth its complexity only if profiling ever shows
/// spawn cost — not before.
library;

import 'dart:isolate';

import 'cell_mesher.dart';
import 'cubed_sphere.dart';
import 'mesh_scheduler.dart';
import 'terrain_field.dart';

/// Meshes each chunk on a background isolate.
class PlatformMeshScheduler implements TerrainMeshScheduler {
  @override
  Future<CellMesh> mesh(
    TerrainField field,
    ChunkKey chunk, {
    required int resolution,
    required double skirtVoxels,
  }) =>
      Isolate.run(
        () => meshTerrainCell(
          field,
          chunk,
          resolution: resolution,
          skirtVoxels: skirtVoxels,
        ),
        debugName: 'terrain-mesh-${chunk.face.name}-${chunk.level}',
      );

  @override
  void dispose() {}
}
