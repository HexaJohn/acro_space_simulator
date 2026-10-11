// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITH `dart:isolate`: persistent workers that
/// hold [TerrainField.base] once and the brush list once per edit change,
/// exactly as `mesh_scheduler_isolate.dart` does (never `Isolate.run` with a
/// DEM field: the copy bills the sending thread). Per job only the
/// directions go out and the radii come back.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'ground_sample_pool.dart';
import 'terrain_brush.dart';
import 'terrain_edits.dart';
import 'terrain_field.dart';

class PlatformGroundSamplePool implements GroundSamplePool {
  PlatformGroundSamplePool({int workers = 3}) : _size = workers;

  final int _size;
  final List<_Worker> _workers = [];
  var _nextJob = 0;
  var _disposed = false;

  @override
  Future<Float64List> sample(TerrainField field, Float64List dirs) {
    if (_disposed) throw StateError('ground sample pool disposed');
    while (_workers.length < _size) {
      _workers.add(_Worker('ground-sample-${_workers.length}'));
    }
    var worker = _workers.first;
    for (final w in _workers) {
      if (w.inFlight < worker.inFlight) worker = w;
    }
    return worker.sample(_nextJob++, field, dirs);
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
  final Map<int, Completer<Float64List>> _jobs = {};
  SendPort? _commands;
  Future<SendPort>? _starting;
  ReceivePort? _results;
  Isolate? _isolate;
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
          } else if (msg is _Done) {
            _jobs.remove(msg.id)?.complete(msg.radii);
          } else if (msg is _Failed) {
            _jobs.remove(msg.id)?.completeError(StateError(msg.error));
          }
        });
        _isolate = await Isolate.spawn(_workerMain, results.sendPort, debugName: debugName);
        final port = await handshake.future;
        _commands = port;
        return port;
      }();

  Future<Float64List> sample(int id, TerrainField field, Float64List dirs) async {
    final commands = _commands ?? await _start();
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
    } else if (!identical(edits, _sentEditsIdentity) || edits.version != _sentEditsVersion) {
      commands.send(_SetEdits(edits.all));
      _sentEditsIdentity = edits;
      _sentEditsVersion = edits.version;
    }
    final completer = Completer<Float64List>();
    _jobs[id] = completer;
    commands.send(_Job(id, dirs));
    return completer.future;
  }

  void dispose() {
    _commands?.send(const _Shutdown());
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _results?.close();
    for (final job in _jobs.values) {
      job.completeError(StateError('ground sample pool disposed'));
    }
    _jobs.clear();
  }
}

class _SetBase {
  const _SetBase(this.field);
  final TerrainField field;
}

class _SetEdits {
  const _SetEdits(this.brushes);
  final List<TerrainBrush> brushes;
}

class _Job {
  const _Job(this.id, this.dirs);
  final int id;
  final Float64List dirs;
}

class _Done {
  const _Done(this.id, this.radii);
  final int id;
  final Float64List radii;
}

class _Failed {
  const _Failed(this.id, this.error);
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
    } else if (msg is _Job) {
      try {
        final field = composed ??= base!.withEdits(edits);
        ready.send(_Done(msg.id, sampleGround(field, msg.dirs)));
      } catch (e) {
        ready.send(_Failed(msg.id, '$e'));
      }
    } else if (msg is _Shutdown) {
      commands.close();
    }
  });
}
