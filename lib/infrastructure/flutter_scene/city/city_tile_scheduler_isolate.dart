// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITH `dart:isolate`: a small pool of
/// PERSISTENT worker isolates. See `city_tile_scheduler.dart` for the seam.
///
/// Persistent rather than `Isolate.run` per job for the reason the terrain
/// pool is (see `mesh_scheduler_isolate.dart`): a fresh isolate starts with
/// an empty archetype library, and a run of buildings against a cold
/// library was a hundred milliseconds — the whole point of the worker is
/// to warm that cache ONCE and keep it. Each worker holds its own full and
/// coarse [CityBuildingLibraries], rebuilt only when the request's knobs
/// move.
///
/// What crosses the boundary: the request going out with the tile's
/// members as typed columns (see `city_tile_columns.dart`) — plain typed
/// lists, copied as blocks on the sending thread and kept by the tile for
/// its next send, which a transferable would not survive — and the result
/// coming back as one packed blob in a [TransferableTypedData]: one copy
/// on the worker, none on the receiver, which matters because a near
/// tile's merged geometry is megabytes and the receiver is the render
/// thread.
library;

import 'dart:async';
import 'dart:isolate';

import 'city_tile_mesher.dart';
import 'city_tile_scheduler.dart';

/// Meshes tiles on a pool of persistent worker isolates.
class PlatformCityTileScheduler implements CityTileScheduler {
  PlatformCityTileScheduler({int workers = 2}) : _size = workers;

  final int _size;
  final List<_Worker> _workers = [];
  var _nextJob = 0;
  var _disposed = false;

  @override
  int get inFlight => _workers.fold(0, (n, w) => n + w.inFlight);

  @override
  Future<CityTileResult> mesh(CityTileRequest request) {
    if (_disposed) throw StateError('scheduler disposed');
    while (_workers.length < _size) {
      _workers.add(_Worker('city-tile-${_workers.length}'));
    }
    // Least-loaded dispatch keeps one slow downtown tile from queueing
    // everything behind it.
    var worker = _workers.first;
    for (final w in _workers) {
      if (w.inFlight < worker.inFlight) worker = w;
    }
    return worker.mesh(_nextJob++, request);
  }

  /// The workers do the meshing; the render thread has nothing to run.
  @override
  int pump(int budgetUs,
          {void Function(CityMeshStepKind kind, int costUs)? onStep}) =>
      0;

  @override
  void dispose() {
    _disposed = true;
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
  }
}

/// One persistent worker isolate plus the bookkeeping of what it owes.
class _Worker {
  _Worker(this.debugName);

  final String debugName;
  final Map<int, Completer<CityTileResult>> _jobs = {};

  SendPort? _commands;
  Future<SendPort>? _starting;
  ReceivePort? _results;
  Isolate? _isolate;

  int get inFlight => _jobs.length;

  Future<SendPort> _start() => _starting ??= () async {
        final results = ReceivePort();
        _results = results;
        final handshake = Completer<SendPort>();
        results.listen((Object? msg) {
          if (msg is SendPort) {
            handshake.complete(msg);
          } else if (msg is _MeshDone) {
            final job = _jobs.remove(msg.id);
            if (job == null) return;
            // Materialising the transferable is the zero-copy half of the
            // trip: the blob becomes ours without being copied again.
            job.complete(
                CityTileResult.unpack(msg.layout, msg.blob.materialize()));
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

  Future<CityTileResult> mesh(int id, CityTileRequest request) {
    // Booked BEFORE the worker is up, synchronously: [inFlight] is what
    // the caller's dispatch and its in-flight cap read, and a job that
    // counted only once the spawn resolved would let a whole frame's
    // queue through the cap on the first submit.
    final completer = Completer<CityTileResult>();
    _jobs[id] = completer;
    final commands = _commands;
    if (commands != null) {
      commands.send(_MeshJob(id, request));
    } else {
      _start().then((port) => port.send(_MeshJob(id, request)),
          onError: (Object e, StackTrace st) =>
              _jobs.remove(id)?.completeError(e, st));
    }
    return completer.future;
  }

  void dispose() {
    _commands?.send(const _Shutdown());
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _results?.close();
    for (final job in _jobs.values) {
      job.completeError(StateError('tile scheduler disposed'));
    }
    _jobs.clear();
  }
}

// ---- Worker-side ----------------------------------------------------------

class _MeshJob {
  const _MeshJob(this.id, this.request);
  final int id;
  final CityTileRequest request;
}

class _MeshDone {
  const _MeshDone(this.id, this.layout, this.blob);
  final int id;
  final CityTilePackedLayout layout;
  final TransferableTypedData blob;
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

  // This worker's archetype libraries, warmed by the first tile and kept
  // for the rest — the job re-syncs them against each request's knobs, so
  // a style switch on the UI thread rebuilds them here too.
  final libraries = CityBuildingLibraries();

  commands.listen((Object? msg) {
    if (msg is _MeshJob) {
      try {
        final result = CityTileMesher.mesh(msg.request, libraries);
        final (layout, blob) = result.pack();
        ready.send(_MeshDone(
            msg.id, layout, TransferableTypedData.fromList([blob])));
      } catch (e) {
        ready.send(_MeshFailed(msg.id, '$e'));
      }
    } else if (msg is _Shutdown) {
      commands.close();
    }
  });
}
