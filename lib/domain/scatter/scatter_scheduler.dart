// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Off-thread scatter cell generation — the same seam `mesh_scheduler.dart`
/// cut for terrain chunks, for the same reason.
///
/// [ScatterPlacement.instancesFor] is a pure function of
/// `(cell, layer, body seed)` — the class docs promise "the main isolate and
/// a mesher isolate independently produce byte-identical results", and this
/// is where that promise is cashed in. A cell costs 5-30 ms (hundreds of
/// candidates, each up to five field evaluations), and the renderer generates
/// several per frame while walking into fresh ground: inline, that is a
/// visible hitch; on an isolate it is free.
///
/// Cancellation is deliberately absent, exactly as for terrain meshes: a
/// stale result costs one wasted list, a cancellation protocol costs a state
/// machine. Callers drop results they no longer want.
library;

import '../terrain/cubed_sphere.dart';
import 'scatter_instance.dart';
import 'scatter_layer.dart';
import 'scatter_placement.dart';
import 'scatter_scheduler_sync.dart'
    if (dart.library.isolate) 'scatter_scheduler_isolate.dart' as platform;

/// Schedules [ScatterPlacement.instancesFor] calls, possibly off-thread.
abstract interface class ScatterGenScheduler {
  /// The best implementation for this platform: isolate-backed where isolates
  /// exist, inline where they do not (web).
  factory ScatterGenScheduler.platform() = platform.PlatformScatterScheduler;

  /// Generate [layer]'s instances for [cell]. The future completes on the
  /// caller's event loop; the work may have happened elsewhere. Deterministic:
  /// the same inputs produce identical instances on every implementation.
  Future<List<ScatterInstance>> generate(
    ScatterPlacement placement,
    ChunkKey cell,
    ScatterLayer layer,
  );

  void dispose();
}

/// Generates inline on the calling thread. The web implementation and the
/// test implementation.
class SyncScatterScheduler implements ScatterGenScheduler {
  @override
  Future<List<ScatterInstance>> generate(
    ScatterPlacement placement,
    ChunkKey cell,
    ScatterLayer layer,
  ) =>
      Future.value(placement.instancesFor(cell, layer));

  @override
  void dispose() {}
}
