// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Weighs what a stretch of code leaves in this isolate's new space, through
/// the VM service (docs/plans/agent-traffic.md §15.2): how `traffic_alloc_test`
/// and the step bench hold the agents to allocating nothing in steady state.
///
/// The service is found through `dart:developer`, the only way a test can
/// reach it. `flutter test` starts the tester without one unless asked
/// (`--enable-vmservice`); [HeapProbe.connect] then answers null and the
/// caller skips. It is spoken to over a plain WebSocket rather than
/// `package:vm_service`, which the app does not depend on.
///
/// What is read is the new space's `used`, from the isolate's own heap
/// report. Two other readings were tried and do not work:
///
/// - The allocation profile's per-class accumulators. They are settled by
///   the collector: garbage made between two collections is partly lost
///   (two million short-lived objects across three collections counted as
///   eleven megabytes of thirty-two), they can fall inside a window with no
///   collection, and a profile taken with `gc: true` reads nothing at all.
/// - The heap's total `used`. Old space's sweeper runs in the background and
///   moves it by tens of kilobytes while nothing is allocated.
///
/// The heap report is a single string, read with a regular expression and
/// never decoded, but receiving it still costs the isolate a steady few
/// hundred kilobytes, the same to within a few. That cost is measured once,
/// and every window is net of it. A collection inside a window makes `used`
/// meaningless, so a long stretch of work is weighed as many short windows,
/// each starting on an emptied new space. A window a collection lands in is
/// thrown away, and another stretch of the same work is weighed in its
/// place.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

/// A connection to this isolate's VM service, for weighing allocations.
class HeapProbe {
  HeapProbe._(this._ws, this._isolateId)
      : _replies = StreamIterator<Object?>(_ws);

  final WebSocket _ws;
  final StreamIterator<Object?> _replies;
  final String _isolateId;
  int _id = 0;
  int? _sampleCost;

  static final RegExp _heaps = RegExp(r'"(new|old)":\{[^{}]*\}');
  static final RegExp _used = RegExp(r'"used":(\d+)');
  static final RegExp _collections = RegExp(r'"collections":(\d+)');

  /// How to run a test so that [connect] finds the service.
  static const String howToRun =
      'needs the VM service: fvm flutter test --enable-vmservice <file>';

  /// A probe on this isolate, or null when the tester runs without a VM
  /// service.
  static Future<HeapProbe?> connect() async {
    final uri = (await Service.getInfo()).serverWebSocketUri;
    final id = Service.getIsolateId(Isolate.current);
    if (uri == null || id == null) return null;
    return HeapProbe._(await WebSocket.connect(uri.toString()), id);
  }

  /// Calls [method] on this isolate; the reply, raw. Requests go one at a
  /// time and nothing is subscribed to, so the next message is the reply.
  Future<String> _call(String method) async {
    _ws.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': '${++_id}',
      'method': method,
      'params': {'isolateId': _isolateId},
    }));
    if (!await _replies.moveNext()) {
      throw StateError('the VM service closed the connection');
    }
    final raw = _replies.current! as String;
    if (raw.startsWith('{"jsonrpc":"2.0","error"')) {
      throw StateError('$method failed: $raw');
    }
    return raw;
  }

  /// New-space bytes in use, and the collections of both spaces so far.
  Future<({int used, int collections})> _sample() async {
    final raw = await _call('getIsolate');
    final at = raw.indexOf('"_heaps"');
    if (at < 0) throw StateError('the isolate reports no heaps');
    var used = -1, collections = 0;
    for (final m in _heaps.allMatches(raw, at).take(2)) {
      final space = m.group(0)!;
      collections += int.parse(_collections.firstMatch(space)!.group(1)!);
      if (m.group(1) == 'new') {
        used = int.parse(_used.firstMatch(space)!.group(1)!);
      }
    }
    if (used < 0) throw StateError('the isolate reports no new space');
    return (used: used, collections: collections);
  }

  /// Empties the heap, so a window starts with the new space bare. A VM
  /// without the private call only makes a collection in a window likelier.
  Future<void> _collect() async {
    try {
      await _call('_collectAllGarbage');
    } on StateError {
      // Without it, a window a collection lands in is simply taken again.
    }
  }

  /// What receiving one sample leaves in new space: the median of a few
  /// back-to-back pairs taken on an emptied heap.
  Future<int> _costOfSample() async {
    final known = _sampleCost;
    if (known != null) return known;
    final costs = <int>[];
    for (var i = 0; i < 7; i++) {
      await _collect();
      final a = await _sample();
      final b = await _sample();
      if (a.collections == b.collections) costs.add(b.used - a.used);
    }
    if (costs.isEmpty) throw StateError('no two samples without a collection');
    costs.sort();
    return _sampleCost = costs[costs.length ~/ 2];
  }

  /// Bytes left in new space by [windows] runs of [work], each run
  /// synchronously in a window of its own, net of what taking the samples
  /// costs. A window a collection lands in is not counted, and [work] runs
  /// again for another: the work must be one stretch of a steady state,
  /// where any stretch weighs what any other does.
  Future<int> growthOver(int windows, void Function() work) async {
    final cost = await _costOfSample();
    var total = 0, counted = 0, lost = 0;
    while (counted < windows) {
      await _collect();
      final w0 = await _sample();
      work();
      final w1 = await _sample();
      if (w1.collections != w0.collections) {
        if (++lost > 2 * windows + 4) {
          throw StateError('collections landed in $lost windows of '
              '${counted + lost}: the work allocates more than new space '
              'holds');
        }
        continue;
      }
      total += w1.used - w0.used - cost;
      counted++;
    }
    return total;
  }

  /// The mean bytes each of [n] calls of [make] leaves, weighed as
  /// [growthOver] weighs [windows] windows of them.
  Future<double> bytesEach(int n, void Function() make,
          {int windows = 4}) async =>
      await growthOver(windows, () {
        for (var i = 0; i < n; i++) {
          make();
        }
      }) /
      (n * windows);

  Future<void> close() => _ws.close();
}
