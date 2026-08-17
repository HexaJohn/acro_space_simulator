// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITH `dart:isolate`: each cell generates on a
/// short-lived background isolate. See `scatter_scheduler.dart` for the seam.
///
/// `Isolate.run` per cell for the same reasons the terrain mesher spawns per
/// chunk (`mesh_scheduler_isolate.dart`): spawn cost is a fraction of a
/// millisecond, the captured state (the placement's [TerrainField] and
/// climate model) is plain objects, and a worker pool buys nothing until
/// profiling says spawn cost matters.
library;

import 'dart:isolate';

import '../terrain/cubed_sphere.dart';
import 'scatter_instance.dart';
import 'scatter_layer.dart';
import 'scatter_placement.dart';
import 'scatter_scheduler.dart';

/// Generates each cell on a background isolate.
class PlatformScatterScheduler implements ScatterGenScheduler {
  @override
  Future<List<ScatterInstance>> generate(
    ScatterPlacement placement,
    ChunkKey cell,
    ScatterLayer layer,
  ) =>
      Isolate.run(
        () => placement.instancesFor(cell, layer),
        debugName: 'scatter-${layer.name}-${cell.face.name}-${cell.level}',
      );

  @override
  void dispose() {}
}
