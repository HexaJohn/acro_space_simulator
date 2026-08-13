// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Off-thread chunk meshing (phase 4c, `docs/plans/terrain-lod.md` §4).
///
/// Meshing a chunk is pure math over a deterministic, seed-driven field, so it
/// can run anywhere — the ONLY thing that has to stay on the render thread is
/// the GPU upload. This interface is the seam the plan requires: a native
/// implementation meshes on a background isolate, the web one (no isolates
/// there) meshes inline on the calling thread. Callers must not import either
/// implementation directly — `TerrainMeshScheduler.platform()` picks via
/// conditional import.
///
/// Cancellation is deliberately absent. A stale result costs one wasted mesh;
/// a cancellation protocol costs a state machine. Callers drop results they no
/// longer want (the generation check in `TerrainNodes`).
library;

import 'cell_mesher.dart';
import 'cubed_sphere.dart';
import 'terrain_field.dart';
import 'mesh_scheduler_sync.dart'
    if (dart.library.isolate) 'mesh_scheduler_isolate.dart' as platform;

/// Schedules [meshTerrainCell] calls, possibly off-thread.
abstract interface class TerrainMeshScheduler {
  /// The best implementation for this platform: isolate-backed where isolates
  /// exist, inline where they do not (web).
  factory TerrainMeshScheduler.platform() = platform.PlatformMeshScheduler;

  /// Mesh [chunk] of [field]. The future completes on the caller's event loop;
  /// the work may have happened elsewhere. Results are deterministic — the
  /// same inputs produce byte-identical geometry on every implementation,
  /// which is what makes moving the work off-thread safe at all.
  Future<CellMesh> mesh(
    TerrainField field,
    ChunkKey chunk, {
    required int resolution,
    required double skirtVoxels,
  });

  void dispose();
}

/// Meshes inline on the calling thread. The web implementation, the test
/// implementation, and the `asyncMeshing` kill-switch fallback.
class SyncTerrainMeshScheduler implements TerrainMeshScheduler {
  @override
  Future<CellMesh> mesh(
    TerrainField field,
    ChunkKey chunk, {
    required int resolution,
    required double skirtVoxels,
  }) =>
      Future.value(meshTerrainCell(
        field,
        chunk,
        resolution: resolution,
        skirtVoxels: skirtVoxels,
      ));

  @override
  void dispose() {}
}
