// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITH `dart:isolate`: one persistent worker
/// that measures one floor at a time (the ground sample pool's pattern,
/// sized to one because measurement is rare — after an editor closes — and a
/// second worker would only race the first for the same cores the frame
/// needs).
///
/// The queue lives on THIS side, not in the worker's mailbox, so a request
/// can still be superseded by a newer one for the same key until the moment
/// it is sent. Exactly one request is in flight at a time.
library;

import 'dart:async';
import 'dart:isolate';

import '../../domain/colony/city/factory/factory_sim_api.dart';
import '../../domain/colony/city/factory/floor_blueprint.dart';
import 'floor_measure_runner.dart';

class PlatformFloorMeasureRunner implements FloorMeasureRunner {
  PlatformFloorMeasureRunner(this.build, {this.setup});

  final FloorSimBuilder build;
  final FloorWorkerSetup? setup;

  final List<_Request> _queue = [];
  _Request? _inFlight;
  var _nextId = 0;
  var _disposed = false;

  SendPort? _commands;
  Future<SendPort>? _starting;
  ReceivePort? _results;
  Isolate? _isolate;

  @override
  int get pending => _queue.length + (_inFlight == null ? 0 : 1);

  @override
  Future<MeasuredRates> measure(
    FloorBlueprint bp, {
    MeasureSettings settings = MeasureSettings.standard,
    String? key,
  }) {
    if (_disposed) {
      return Future.error(StateError('floor measure runner disposed'));
    }
    final req = _Request(_nextId++, key, bp.toJson(), settings.toJson());
    if (key != null) {
      for (var i = 0; i < _queue.length; i++) {
        final old = _queue[i];
        if (old.key != key) continue;
        // Superseded: the older caller waits for the newer layout's rates.
        req.waiters.addAll(old.waiters);
        _queue.removeAt(i);
        break;
      }
    }
    _queue.add(req);
    final f = req.waiters.last.future;
    _pump();
    return f;
  }

  Future<SendPort> _start() => _starting ??= () async {
    final results = ReceivePort();
    _results = results;
    final handshake = Completer<SendPort>();
    results.listen((Object? msg) {
      if (msg is SendPort) {
        handshake.complete(msg);
      } else if (msg is _Done) {
        _finish(msg.id, rates: MeasuredRates.fromJson(msg.rates));
      } else if (msg is _Failed) {
        _finish(msg.id, error: StateError(msg.error));
      }
    });
    _isolate = await Isolate.spawn(
      _workerMain,
      _Boot(results.sendPort, build, setup),
      debugName: 'floor-measure',
    );
    final port = await handshake.future;
    _commands = port;
    return port;
  }();

  void _pump() {
    if (_disposed || _inFlight != null || _queue.isEmpty) return;
    final req = _queue.removeAt(0);
    _inFlight = req;
    final commands = _commands;
    if (commands != null) {
      commands.send(_Job(req.id, req.blueprint, req.settings));
      return;
    }
    _start().then((port) {
      if (_disposed) return;
      port.send(_Job(req.id, req.blueprint, req.settings));
    }, onError: (Object e) => _finish(req.id, error: e));
  }

  void _finish(int id, {MeasuredRates? rates, Object? error}) {
    final req = _inFlight;
    if (req == null || req.id != id) return;
    _inFlight = null;
    for (final w in req.waiters) {
      if (rates != null) {
        w.complete(rates);
      } else {
        w.completeError(error ?? StateError('floor measure failed'));
      }
    }
    _pump();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _commands?.send(const _Shutdown());
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _results?.close();
    final waiting = [?_inFlight, ..._queue];
    _inFlight = null;
    _queue.clear();
    for (final r in waiting) {
      for (final w in r.waiters) {
        w.completeError(StateError('floor measure runner disposed'));
      }
    }
  }
}

class _Request {
  _Request(this.id, this.key, this.blueprint, this.settings);
  final int id;
  final String? key;
  final Map<String, Object?> blueprint;
  final Map<String, Object?> settings;
  final List<Completer<MeasuredRates>> waiters = [Completer()];
}

class _Boot {
  const _Boot(this.ready, this.build, this.setup);
  final SendPort ready;
  final FloorSimBuilder build;
  final FloorWorkerSetup? setup;
}

class _Job {
  const _Job(this.id, this.blueprint, this.settings);
  final int id;
  final Map<String, Object?> blueprint;
  final Map<String, Object?> settings;
}

class _Done {
  const _Done(this.id, this.rates);
  final int id;
  final Map<String, Object?> rates;
}

class _Failed {
  const _Failed(this.id, this.error);
  final int id;
  final String error;
}

class _Shutdown {
  const _Shutdown();
}

void _workerMain(_Boot boot) {
  final commands = ReceivePort();
  final ready = boot.ready;
  var setUp = false;
  ready.send(commands.sendPort);
  commands.listen((Object? msg) {
    if (msg is _Job) {
      try {
        final setup = boot.setup;
        if (!setUp && setup != null) setup();
        setUp = true;
        ready.send(
          _Done(
            msg.id,
            measureBlueprintJson(boot.build, msg.blueprint, msg.settings),
          ),
        );
      } catch (e) {
        ready.send(_Failed(msg.id, '$e'));
      }
    } else if (msg is _Shutdown) {
      commands.close();
    }
  });
}
