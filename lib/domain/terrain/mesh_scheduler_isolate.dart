// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITH `dart:isolate`: a small pool of
/// PERSISTENT worker isolates. See `mesh_scheduler.dart` for the seam.
///
/// This replaced `Isolate.run`-per-job the day profiling caught the send
/// cost the old header said to wait for: `Isolate.run` deep-copies the
/// captured [TerrainField] into the fresh isolate — INCLUDING the decoded
/// DEM pyramid — and the copy bills the SENDING thread. Measured: 6 submits
/// = 29 ms (Moon, 4 MB) / 72 ms (Earth, 16 MB) of main-thread stall, every
/// frame, for as long as a streaming backlog lasts. That was the largest
/// single term in the "sceneSync: terrain 400ms" frames.
///
/// The pool ships heavyweight state ONCE and small things thereafter:
///  * [TerrainField.base] (noise + detail + DEM) — once per body, per worker,
///    keyed by instance identity;
///  * the brush list — once per edit change, keyed by `TerrainEdits.version`
///    (brushes are a few hundred bytes);
///  * per job, only `(chunk key, resolution, skirtVoxels)`.
/// Result buffers still copy on the way back, but that bills the worker, and
/// a cell mesh is hundreds of KB, not tens of MB.
library;

import 'dart:async';
import 'dart:isolate';

import 'cell_mesher.dart';
import 'cubed_sphere.dart';
import 'mesh_scheduler.dart';
import 'terrain_brush.dart';
import 'terrain_edits.dart';
import 'terrain_field.dart';

/// Meshes chunks on a pool of persistent worker isolates.
class PlatformMeshScheduler implements TerrainMeshScheduler {
  PlatformMeshScheduler({int workers = 3}) : _size = workers;

  final int _size;
  final List<_Worker> _workers = [];
  var _nextJob = 0;
  var _disposed = false;

  @override
  Future<CellMesh> mesh(
    TerrainField field,
    ChunkKey chunk, {
    required int resolution,
    required double skirtVoxels,
  }) async {
    if (_disposed) throw StateError('scheduler disposed');
    while (_workers.length < _size) {
      _workers.add(_Worker('terrain-mesh-${_workers.length}'));
    }
    // Least-loaded dispatch keeps one slow (boosted-resolution) chunk from
    // queueing everything behind it.
    var worker = _workers.first;
    for (final w in _workers) {
      if (w.inFlight < worker.inFlight) worker = w;
    }
    return worker.mesh(_nextJob++, field, chunk,
        resolution: resolution, skirtVoxels: skirtVoxels);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
  }
}

/// One persistent worker isolate plus the bookkeeping of what it holds.
class _Worker {
  _Worker(this.debugName);

  final String debugName;
  final Map<int, Completer<CellMesh>> _jobs = {};

  SendPort? _commands;
  Future<SendPort>? _starting;
  ReceivePort? _results;
  Isolate? _isolate;

  /// What this worker currently holds, by identity/version — the whole point
  /// of the pool. See the library docs.
  TerrainField? _sentBase;
  Object? _sentEditsIdentity;
  int _sentEditsVersion = -1;

  int get inFlight => _jobs.length;

  Future<SendPort> _start() => _starting ??= () async {
        final results = ReceivePort();
        _results = results;
        final handshake = Completer<SendPort>();
        results.listen((Object? msg) {
          if (msg is SendPort) {
            handshake.complete(msg);
          } else if (msg is _MeshDone) {
            _jobs.remove(msg.id)?.complete(msg.cell);
          } else if (msg is _MeshFailed) {
            _jobs.remove(msg.id)?.completeError(StateError(msg.error));
          }
        });
        _isolate = await Isolate.spawn(
          _workerMain,
          results.sendPort,
          debugName: debugName,
        );
        final port = await handshake.future;
        _commands = port;
        return port;
      }();

  Future<CellMesh> mesh(
    int id,
    TerrainField field,
    ChunkKey chunk, {
    required int resolution,
    required double skirtVoxels,
  }) async {
    final commands = _commands ?? await _start();

    // Ship state only when it changed since this worker last saw it.
    final base = field.base;
    if (!identical(base, _sentBase)) {
      commands.send(_SetBase(base));
      _sentBase = base;
      _sentEditsIdentity = null;
      _sentEditsVersion = -1;
    }
    final edits = field.edits;
    if (edits == null || edits.isEmpty) {
      if (_sentEditsIdentity != null || _sentEditsVersion != 0) {
        commands.send(const _SetEdits([]));
        _sentEditsIdentity = null;
        _sentEditsVersion = 0;
      }
    } else if (!identical(edits, _sentEditsIdentity) ||
        edits.version != _sentEditsVersion) {
      commands.send(_SetEdits(edits.all));
      _sentEditsIdentity = edits;
      _sentEditsVersion = edits.version;
    }

    final completer = Completer<CellMesh>();
    _jobs[id] = completer;
    commands.send(_MeshJob(id, chunk, resolution, skirtVoxels));
    return completer.future;
  }

  void dispose() {
    _commands?.send(const _Shutdown());
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _results?.close();
    for (final job in _jobs.values) {
      job.completeError(StateError('mesh scheduler disposed'));
    }
    _jobs.clear();
  }
}

// ---- Worker-side ----------------------------------------------------------

class _SetBase {
  const _SetBase(this.field);
  final TerrainField field;
}

class _SetEdits {
  const _SetEdits(this.brushes);
  final List<TerrainBrush> brushes;
}

class _MeshJob {
  const _MeshJob(this.id, this.chunk, this.resolution, this.skirtVoxels);
  final int id;
  final ChunkKey chunk;
  final int resolution;
  final double skirtVoxels;
}

class _MeshDone {
  const _MeshDone(this.id, this.cell);
  final int id;
  final CellMesh cell;
}

class _MeshFailed {
  const _MeshFailed(this.id, this.error);
  final int id;
  final String error;
}

class _Shutdown {
  const _Shutdown();
}

void _workerMain(SendPort ready) {
  final commands = ReceivePort();
  ready.send(commands.sendPort);

  TerrainField? base;
  TerrainEdits? edits;
  TerrainField? composed;

  commands.listen((Object? msg) {
    if (msg is _SetBase) {
      base = msg.field;
      composed = null;
    } else if (msg is _SetEdits) {
      edits = msg.brushes.isEmpty ? null : TerrainEdits.of(msg.brushes);
      composed = null;
    } else if (msg is _MeshJob) {
      try {
        final field = composed ??= base!.withEdits(edits);
        final cell = meshTerrainCell(
          field,
          msg.chunk,
          resolution: msg.resolution,
          skirtVoxels: msg.skirtVoxels,
        );
        ready.send(_MeshDone(msg.id, cell));
      } catch (e) {
        ready.send(_MeshFailed(msg.id, '$e'));
      }
    } else if (msg is _Shutdown) {
      commands.close();
    }
  });
}
