// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITH `dart:isolate`: a small pool of
/// PERSISTENT worker isolates, mirroring `mesh_scheduler_isolate.dart` and
/// for the same measured reason — `Isolate.run` per cell deep-copied the
/// placement's [TerrainField] (with its DEM pyramid) on the SENDING thread,
/// per job. The pool ships the pristine field and climate model once per
/// body, the brush list once per edit change, and per job only the cell key
/// and layer index.
library;

import 'dart:async';
import 'dart:isolate';

import '../planetary/planet_surface.dart';
import '../terrain/cubed_sphere.dart';
import '../terrain/terrain_brush.dart';
import '../terrain/terrain_edits.dart';
import '../terrain/terrain_field.dart';
import 'scatter_instance.dart';
import 'scatter_layer.dart';
import 'scatter_placement.dart';
import 'scatter_scheduler.dart';

/// Generates cells on a pool of persistent worker isolates.
class PlatformScatterScheduler implements ScatterGenScheduler {
  PlatformScatterScheduler({int workers = 2}) : _size = workers;

  final int _size;
  final List<_Worker> _workers = [];
  var _nextJob = 0;
  var _disposed = false;

  @override
  Future<List<ScatterInstance>> generate(
    ScatterPlacement placement,
    ChunkKey cell,
    ScatterLayer layer,
  ) async {
    if (_disposed) throw StateError('scheduler disposed');
    // Layers are dispatched by INDEX into the shared catalogue: a
    // ScatterLayer is a const with function-free plain data, but the index
    // is smaller still and pins worker and caller to the same list.
    final layerIndex = ScatterLayers.all.indexOf(layer);
    if (layerIndex < 0) {
      // A custom layer (tests): fall back to inline generation.
      return placement.instancesFor(cell, layer);
    }
    while (_workers.length < _size) {
      _workers.add(_Worker('scatter-gen-${_workers.length}'));
    }
    var worker = _workers.first;
    for (final w in _workers) {
      if (w.inFlight < worker.inFlight) worker = w;
    }
    return worker.generate(_nextJob++, placement, cell, layerIndex);
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

class _Worker {
  _Worker(this.debugName);

  final String debugName;
  final Map<int, Completer<List<ScatterInstance>>> _jobs = {};

  SendPort? _commands;
  Future<SendPort>? _starting;
  ReceivePort? _results;
  Isolate? _isolate;

  TerrainField? _sentBase;
  PlanetSurface? _sentSurface;
  int _sentBodySeed = -1;
  double _sentVegetationCap = double.nan;
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
          } else if (msg is _GenDone) {
            _jobs.remove(msg.id)?.complete(msg.instances);
          } else if (msg is _GenFailed) {
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

  Future<List<ScatterInstance>> generate(
    int id,
    ScatterPlacement placement,
    ChunkKey cell,
    int layerIndex,
  ) async {
    final commands = _commands ?? await _start();

    final base = placement.field.base;
    if (!identical(base, _sentBase) ||
        !identical(placement.surface, _sentSurface) ||
        placement.bodySeed != _sentBodySeed ||
        placement.vegetationCap != _sentVegetationCap) {
      commands.send(_SetContext(
        base,
        placement.surface,
        placement.bodySeed,
        placement.vegetationCap,
      ));
      _sentBase = base;
      _sentSurface = placement.surface;
      _sentBodySeed = placement.bodySeed;
      _sentVegetationCap = placement.vegetationCap;
      _sentEditsIdentity = null;
      _sentEditsVersion = -1;
    }
    final edits = placement.field.edits;
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

    final completer = Completer<List<ScatterInstance>>();
    _jobs[id] = completer;
    commands.send(_GenJob(id, cell, layerIndex));
    return completer.future;
  }

  void dispose() {
    _commands?.send(const _Shutdown());
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _results?.close();
    for (final job in _jobs.values) {
      job.completeError(StateError('scatter scheduler disposed'));
    }
    _jobs.clear();
  }
}

// ---- Worker-side ----------------------------------------------------------

class _SetContext {
  const _SetContext(this.field, this.surface, this.bodySeed, this.vegetationCap);
  final TerrainField field;
  final PlanetSurface surface;
  final int bodySeed;
  final double vegetationCap;
}

class _SetEdits {
  const _SetEdits(this.brushes);
  final List<TerrainBrush> brushes;
}

class _GenJob {
  const _GenJob(this.id, this.cell, this.layerIndex);
  final int id;
  final ChunkKey cell;
  final int layerIndex;
}

class _GenDone {
  const _GenDone(this.id, this.instances);
  final int id;
  final List<ScatterInstance> instances;
}

class _GenFailed {
  const _GenFailed(this.id, this.error);
  final int id;
  final String error;
}

class _Shutdown {
  const _Shutdown();
}

void _workerMain(SendPort ready) {
  final commands = ReceivePort();
  ready.send(commands.sendPort);

  _SetContext? context;
  TerrainEdits? edits;
  ScatterPlacement? placement;

  commands.listen((Object? msg) {
    if (msg is _SetContext) {
      context = msg;
      placement = null;
    } else if (msg is _SetEdits) {
      edits = msg.brushes.isEmpty ? null : TerrainEdits.of(msg.brushes);
      placement = null;
    } else if (msg is _GenJob) {
      try {
        final ctx = context!;
        final p = placement ??= ScatterPlacement(
          field: ctx.field.withEdits(edits),
          surface: ctx.surface,
          bodySeed: ctx.bodySeed,
          vegetationCap: ctx.vegetationCap,
        );
        ready.send(_GenDone(
          msg.id,
          p.instancesFor(msg.cell, ScatterLayers.all[msg.layerIndex]),
        ));
      } catch (e) {
        ready.send(_GenFailed(msg.id, '$e'));
      }
    } else if (msg is _Shutdown) {
      commands.close();
    }
  });
}
