// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Off-thread tile meshing for the colony renderer.
///
/// Meshing a tile is pure work over the frame's snapshot objects (see
/// `city_tile_mesher.dart`), so it can run anywhere — the ONLY thing that
/// has to stay on the render thread is the GPU upload. This interface is
/// the seam, modelled on `TerrainMeshScheduler`: the native binding meshes
/// on a small pool of persistent worker isolates, the web binding (no
/// isolates there) meshes inline on the calling thread, in the same small
/// steps the build loop used to run, under the same budget. Callers must
/// not import either binding directly — [CityTileScheduler.platform] picks
/// via conditional import.
///
/// Cancellation is deliberately absent, as it is for the terrain. A job
/// runs to its end once submitted, and the caller drops a result it no
/// longer wants ([PendingTileJobs]). That is also what the build loop has
/// always done with its own jobs: a tile one camera cell stale is
/// invisible, a tile that never finishes is not.
library;

import 'dart:async';

import 'city_tile_mesher.dart';
import 'city_tile_scheduler_sync.dart'
    if (dart.library.isolate) 'city_tile_scheduler_isolate.dart' as platform;

/// Schedules tile meshing, possibly off-thread.
abstract interface class CityTileScheduler {
  /// The best implementation for this platform: isolate-backed where
  /// isolates exist, inline where they do not (web).
  factory CityTileScheduler.platform() = platform.PlatformCityTileScheduler;

  /// Mesh one tile. The future completes on the caller's event loop; the
  /// work may have happened elsewhere. Results are deterministic — the same
  /// request produces byte-identical geometry and the same archetype keys
  /// on every implementation, which is what makes moving the work
  /// off-thread safe at all (see the mesher's library docs).
  Future<CityTileResult> mesh(CityTileRequest request);

  /// Jobs submitted and not yet answered.
  int get inFlight;

  /// Give the scheduler UI-thread time: at most [budgetUs] microseconds of
  /// meshing steps, nearest-submitted first. The isolate binding does its
  /// work elsewhere and returns 0 without touching the clock; the inline
  /// binding runs the steps it would otherwise have nowhere to run, and
  /// reports each one's kind and cost through [onStep] so the caller's
  /// panel sees them. Returns how many steps ran.
  int pump(int budgetUs,
      {void Function(CityMeshStepKind kind, int costUs)? onStep});

  void dispose();
}

/// Meshes inline on the calling thread, a step at a time under [pump]'s
/// budget. The web implementation, the test implementation, and the path
/// that keeps the old in-thread build alive where no worker exists.
///
/// [mesh] only queues; nothing runs until the caller pumps. That is the
/// contract the build loop wants — it decides how much of a frame the
/// meshing may take — and it is why the future is never completed
/// synchronously.
class SyncCityTileScheduler implements CityTileScheduler {
  SyncCityTileScheduler({CityBuildingLibraries? libraries})
      : _libraries = libraries ?? CityBuildingLibraries();

  final CityBuildingLibraries _libraries;
  final List<_InlineJob> _queue = [];

  /// Microseconds the last step of each kind took: the budget loop will not
  /// start a step whose kind last cost more than the frame has left.
  final Map<CityMeshStepKind, int> _stepCostUs = {};
  var _disposed = false;

  @override
  int get inFlight => _queue.length;

  @override
  Future<CityTileResult> mesh(CityTileRequest request) {
    if (_disposed) throw StateError('scheduler disposed');
    final job = _InlineJob(CityTileMeshJob(request, _libraries));
    _queue.add(job);
    return job.done.future;
  }

  @override
  int pump(int budgetUs,
      {void Function(CityMeshStepKind kind, int costUs)? onStep}) {
    final sw = Stopwatch()..start();
    var steps = 0;
    // Nearest first: the caller submits in that order and the queue keeps
    // it. Any budget at all runs one step — judged before the clock, so a
    // frame that grants a microsecond gets its step and not the clock's
    // opinion of how long the grant took to read — or a step dearer than
    // the whole budget would never run at all. No budget runs none.
    while (_queue.isNotEmpty &&
        (steps == 0 ? budgetUs > 0 : sw.elapsedMicroseconds < budgetUs)) {
      final job = _queue.first;
      final next = job.mesh.steps.last.kind;
      final lastUs = _stepCostUs[next];
      if (steps > 0 &&
          lastUs != null &&
          sw.elapsedMicroseconds + lastUs > budgetUs) {
        break;
      }
      final startUs = sw.elapsedMicroseconds;
      try {
        job.mesh.step();
      } catch (e, st) {
        _queue.removeAt(0);
        job.done.completeError(e, st);
        continue;
      }
      final costUs = sw.elapsedMicroseconds - startUs;
      _stepCostUs[next] = costUs;
      onStep?.call(next, costUs);
      steps++;
      if (job.mesh.done) {
        _queue.removeAt(0);
        job.done.complete(job.mesh.result);
      }
    }
    return steps;
  }

  /// Run everything queued to completion, whatever it costs: for tests and
  /// for callers that want the answer now.
  void pumpAll() {
    while (_queue.isNotEmpty) {
      pump(1 << 30);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final job in _queue) {
      job.done.completeError(StateError('tile scheduler disposed'));
    }
    _queue.clear();
    _libraries.clear();
  }
}

class _InlineJob {
  _InlineJob(this.mesh);
  final CityTileMeshJob mesh;
  final Completer<CityTileResult> done = Completer<CityTileResult>();
}

/// The book of which build each tile is waiting on, so a result that comes
/// back for a build the tile has since abandoned — the tile dropped and
/// re-cut by a structure change, its key moved on before its job was ever
/// submitted — is dropped rather than uploaded.
///
/// One entry per tile: a tile has at most one job in flight, and the job's
/// key is the build key it answers. A result whose key differs from the
/// tile's entry is stale; one that matches clears the entry, so a second
/// copy of the same answer (two jobs for one key, across a re-bucket that
/// left the structure alone) is dropped too.
class PendingTileJobs {
  final Map<String, String> _keys = {};

  int get count => _keys.length;

  bool isPending(String tileKey) => _keys.containsKey(tileKey);

  /// The build key [tileKey] is now waiting on; replaces any earlier one.
  void start(String tileKey, String key) => _keys[tileKey] = key;

  /// Whether [result] answers the build its tile is waiting on. Clears the
  /// entry when it does.
  bool accept(CityTileResult result) {
    if (_keys[result.tileKey] != result.key) return false;
    _keys.remove(result.tileKey);
    return true;
  }

  /// The tile no longer waits on anything: its job, if still running, is
  /// answered into the void.
  void forget(String tileKey) => _keys.remove(tileKey);

  void clear() => _keys.clear();
}
