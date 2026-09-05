// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The VM timeline as spans, and the questions the perf tools ask of it:
/// which frames ran long, what ran inside them, what the collector cost.
/// Shared by `frame_spikes.dart` (a static window) and `city_perf_ab.dart`
/// (a window per camera pattern).
library;

import 'dart:io';

import 'package:vm_service/vm_service.dart';

/// One timeline span: complete events carry their own duration; begin/end
/// pairs are matched per thread, async begin/end pairs by id and name.
typedef Span = ({String name, int tid, int ts, int dur, String cat});

/// Starts recording the Dart, GC and embedder streams and returns the
/// clock the window began at.
Future<int> beginTimeline(VmService vm) async {
  await vm.setVMTimelineFlags(['Dart', 'GC', 'Embedder']);
  await vm.clearVMTimeline();
  return (await vm.getVMTimelineMicros()).timestamp!;
}

/// Ends the window begun at [t0] and returns its spans.
Future<List<Span>> endTimeline(VmService vm, int t0) async {
  final t1 = (await vm.getVMTimelineMicros()).timestamp!;
  final timeline =
      await vm.getVMTimeline(timeOriginMicros: t0, timeExtentMicros: t1 - t0);
  return spansOf(timeline.traceEvents ?? const <TimelineEvent>[]);
}

/// A window longer than the VM's ring buffer, drained as it goes.
///
/// The timeline recorder is a ring of a few megabytes: at a hundred frames
/// a second with the GC and embedder streams on it holds about three
/// seconds, and a twelve-second sweep read at its end kept only its tail
/// — the stalls at the start of a pattern, where the camera first looks at
/// unbuilt ground, were never in it. Call [drain] every couple of seconds
/// and [end] once; the spans of every drain are one list.
class TimelineWindow {
  TimelineWindow._(this.vm, this.t0) : _from = t0;
  final VmService vm;
  final int t0;
  final List<Span> _spans = [];
  int _from;

  static Future<TimelineWindow> begin(VmService vm) async {
    final t0 = await beginTimeline(vm);
    return TimelineWindow._(vm, t0);
  }

  /// Fetch what the buffer holds since the last drain and clear it.
  Future<void> drain() async {
    final now = (await vm.getVMTimelineMicros()).timestamp!;
    final timeline = await vm.getVMTimeline(
        timeOriginMicros: _from, timeExtentMicros: now - _from);
    _spans.addAll(spansOf(timeline.traceEvents ?? const <TimelineEvent>[]));
    await vm.clearVMTimeline();
    _from = now;
  }

  Future<List<Span>> end() async {
    await drain();
    return _spans;
  }
}

List<Span> spansOf(List<TimelineEvent> events) {
  final spans = <Span>[];
  final open = <String, List<Map<String, dynamic>>>{};
  for (final e in events) {
    final j = e.json ?? const {};
    final ph = j['ph'];
    final name = '${j['name']}';
    final tid = (j['tid'] as num?)?.toInt() ?? 0;
    final ts = (j['ts'] as num?)?.toInt() ?? 0;
    final cat = '${j['cat'] ?? ''}';
    if (ph == 'X') {
      spans.add((
        name: name,
        tid: tid,
        ts: ts,
        dur: (j['dur'] as num?)?.toInt() ?? 0,
        cat: cat
      ));
    } else if (ph == 'B') {
      (open['$tid'] ??= []).add(j);
    } else if (ph == 'E') {
      final stack = open['$tid'];
      if (stack == null || stack.isEmpty) continue;
      final b = stack.removeLast();
      final bts = (b['ts'] as num?)?.toInt() ?? 0;
      spans.add((
        name: '${b['name']}',
        tid: tid,
        ts: bts,
        dur: ts - bts,
        cat: '${b['cat'] ?? ''}'
      ));
    } else if (ph == 'b') {
      (open['async/${j['id']}/$name'] ??= []).add(j);
    } else if (ph == 'e') {
      final stack = open['async/${j['id']}/$name'];
      if (stack == null || stack.isEmpty) continue;
      final b = stack.removeLast();
      final bts = (b['ts'] as num?)?.toInt() ?? 0;
      spans.add((name: name, tid: tid, ts: bts, dur: ts - bts, cat: cat));
    }
  }
  return spans;
}

/// The framework's UI-thread frames (its `Frame` TimelineTask), by start.
List<Span> framesOf(List<Span> spans) =>
    spans.where((s) => s.name == 'Frame').toList()
      ..sort((a, b) => a.ts.compareTo(b.ts));

/// Prints the collector's cost in the window and the [count] longest
/// frames with the longest spans that overlapped each, on any thread.
void reportSpikes(List<Span> spans, int t0,
    {double thresholdMs = 14, int count = 6, String indent = ''}) {
  final frames = framesOf(spans);
  final long = frames.where((f) => f.dur / 1000.0 >= thresholdMs).toList()
    ..sort((a, b) => b.dur.compareTo(a.dur));
  final gcs = spans
      .where((s) => s.cat.contains('GC') || s.name.startsWith('Collect'))
      .toList();
  final scavenges =
      gcs.where((g) => g.name == 'CollectNewGeneration').toList();
  final olds = gcs
      .where((g) =>
          g.name == 'CollectOldGeneration' ||
          g.name == 'CollectAllGarbage' ||
          g.name.startsWith('Mark') ||
          g.name.startsWith('Sweep'))
      .toList()
    ..sort((a, b) => b.dur.compareTo(a.dur));
  double ms(int us) => us / 1000.0;
  String f(double v) => v.toStringAsFixed(1);
  stdout.writeln('$indent${frames.length} frames, ${long.length} over '
      '${f(thresholdMs)} ms; scavenges ${scavenges.length}'
      '${scavenges.isEmpty ? '' : ' avg ${f(scavenges.fold<int>(0, (a, g) => a + g.dur) / scavenges.length / 1000)} ms'}'
      '; old-gen spans ${olds.length}'
      '${olds.isEmpty ? '' : ' longest ${f(ms(olds.first.dur))} ms ${olds.first.name}'}');
  // Stalls BETWEEN frames: the isolate paused (a group-wide collection,
  // a safepoint waited on a worker) shows as a gap, not as a long frame,
  // and the ticker's dt — the panel's worst-of-90 — counts it.
  final gaps = <({int ts, int dur})>[];
  for (var i = 1; i < frames.length; i++) {
    final gap = frames[i].ts - (frames[i - 1].ts + frames[i - 1].dur);
    if (gap >= 40000) gaps.add((ts: frames[i - 1].ts + frames[i - 1].dur, dur: gap));
  }
  gaps.sort((a, b) => b.dur.compareTo(a.dur));
  for (final g in gaps.take(count)) {
    stdout.writeln('$indent-- gap @${((g.ts - t0) / 1e6).toStringAsFixed(2)}s  '
        '${f(ms(g.dur))} ms between frames');
    final inside = spans
        .where((s) =>
            s.name != 'Frame' &&
            s.ts < g.ts + g.dur &&
            s.ts + s.dur > g.ts &&
            // Every thread, the raster thread included: a gap with no Dart
            // span in it is the frame pipeline waiting on the GPU side.
            s.dur >= 500)
        .toList()
      ..sort((a, b) => b.dur.compareTo(a.dur));
    final seen = <String>{};
    for (final s in inside) {
      if (!seen.add('${s.tid}/${s.name}')) continue;
      stdout.writeln('$indent     ${f(ms(s.dur)).padLeft(7)} ms  t${s.tid}  ${s.name}'
          '${s.cat.isEmpty ? '' : '  [${s.cat}]'}');
      if (seen.length >= 8) break;
    }
  }
  for (final fr in long.take(count)) {
    stdout.writeln(
        '$indent-- frame @${((fr.ts - t0) / 1e6).toStringAsFixed(2)}s  '
        '${f(ms(fr.dur))} ms');
    final inside = spans
        .where((s) =>
            s.name != 'Frame' &&
            s.ts < fr.ts + fr.dur &&
            s.ts + s.dur > fr.ts &&
            s.dur >= 500 &&
            !s.cat.contains('Embedder'))
        .toList()
      ..sort((a, b) => b.dur.compareTo(a.dur));
    final seen = <String>{};
    for (final s in inside) {
      if (!seen.add('${s.tid}/${s.name}')) continue;
      stdout.writeln('$indent     ${f(ms(s.dur)).padLeft(7)} ms  ${s.name}'
          '${s.cat.isEmpty ? '' : '  [${s.cat}]'}');
      if (seen.length >= 8) break;
    }
  }
}
