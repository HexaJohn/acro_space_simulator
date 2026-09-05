// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Names the long frames. Records the VM timeline (Dart, GC and embedder
/// streams) for a few seconds, then prints every UI-thread frame over the
/// threshold with what ran inside it — the Flutter framework's own Build,
/// Layout and Paint spans, garbage collections, and any `Timeline` spans the
/// app emits. The perf panel's "worst 90" says a spike exists; this says
/// what it was.
///
///   dart run tool/frame_spikes.dart <vm-service-uri> [seconds] [thresholdMs]
library;

import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final seconds = positional.length > 1 ? int.parse(positional[1]) : 10;
  final thresholdMs = positional.length > 2 ? double.parse(positional[2]) : 16.0;
  final vm = await vmServiceConnectUri(ws);

  final isolateId = (await vm.getVM()).isolates!.first.id!;
  // `--perf=false` hides the studio's perf panel first — the A/B for "is it
  // the panel's paragraphs the collector is finalising".
  // Any `--name=value` is passed straight to the studio's dev hook before
  // recording (perf, shadows, atmosphere, distance, elevation...), so one
  // run can A/B the collector against the scene it is collecting.
  for (final a in args) {
    if (!a.startsWith('--')) continue;
    final eq = a.indexOf('=');
    if (eq < 0) continue;
    final name = a.substring(2, eq), value = a.substring(eq + 1);
    await vm.callServiceExtension('ext.acro.citystudio',
        isolateId: isolateId, args: {name: value});
    stdout.writeln('== $name=$value');
  }
  if (args.any((a) => a.startsWith('--'))) {
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  await vm.setVMTimelineFlags(['Dart', 'GC', 'Embedder']);
  await vm.clearVMTimeline();
  // Two snapshots, diffed: `reset` on the accumulators does not always
  // take, and the lifetime totals say nothing about the window.
  final allocBefore = await vm.getAllocationProfile(isolateId);
  final t0 = (await vm.getVMTimelineMicros()).timestamp!;
  stdout.writeln('== recording ${seconds}s...');
  await Future<void>.delayed(Duration(seconds: seconds));
  final t1 = (await vm.getVMTimelineMicros()).timestamp!;
  final alloc = await vm.getAllocationProfile(isolateId);
  final timeline = await vm.getVMTimeline(timeOriginMicros: t0, timeExtentMicros: t1 - t0);
  final events = timeline.traceEvents ?? const <TimelineEvent>[];

  // Complete events (ph 'X') carry dur; begin/end pairs (B/E) are matched
  // per thread.
  final spans = <({String name, int tid, int ts, int dur, String cat})>[];
  final open = <String, List<Map<String, dynamic>>>{};
  for (final e in events) {
    final j = e.json ?? const {};
    final ph = j['ph'];
    final name = '${j['name']}';
    final tid = (j['tid'] as num?)?.toInt() ?? 0;
    final ts = (j['ts'] as num?)?.toInt() ?? 0;
    final cat = '${j['cat'] ?? ''}';
    if (ph == 'X') {
      spans.add((name: name, tid: tid, ts: ts, dur: (j['dur'] as num?)?.toInt() ?? 0, cat: cat));
    } else if (ph == 'B') {
      (open['$tid'] ??= []).add(j);
    } else if (ph == 'E') {
      final stack = open['$tid'];
      if (stack == null || stack.isEmpty) continue;
      final b = stack.removeLast();
      final bts = (b['ts'] as num?)?.toInt() ?? 0;
      spans.add((name: '${b['name']}', tid: tid, ts: bts, dur: ts - bts, cat: '${b['cat'] ?? ''}'));
    } else if (ph == 'b') {
      // Async spans (the framework's Frame is a TimelineTask): matched by
      // id and name, not by thread.
      (open['async/${j['id']}/$name'] ??= []).add(j);
    } else if (ph == 'e') {
      final stack = open['async/${j['id']}/$name'];
      if (stack == null || stack.isEmpty) continue;
      final b = stack.removeLast();
      final bts = (b['ts'] as num?)?.toInt() ?? 0;
      spans.add((name: name, tid: tid, ts: bts, dur: ts - bts, cat: cat));
    }
  }
  stdout.writeln('== ${events.length} events, ${spans.length} spans');

  // Frames: the framework wraps each UI frame in a "Frame" span (Dart
  // stream) on the UI thread; the embedder emits its own on the raster side.
  final frames = spans.where((s) => s.name == 'Frame').toList()
    ..sort((a, b) => a.ts.compareTo(b.ts));
  final uiTids = <int, int>{};
  for (final f in frames) {
    uiTids.update(f.tid, (n) => n + 1, ifAbsent: () => 1);
  }
  stdout.writeln('== ${frames.length} Frame spans on threads $uiTids');
  final long = frames.where((f) => f.dur / 1000.0 >= thresholdMs).toList();
  stdout.writeln('== ${long.length} frames >= ${thresholdMs.toStringAsFixed(1)} ms');
  final gcs = spans.where((s) => s.cat.contains('GC') || s.name.startsWith('Collect')).toList()
    ..sort((a, b) => b.dur.compareTo(a.dur));
  stdout.writeln('== ${gcs.length} GC spans, total ${(gcs.fold<int>(0, (a, s) => a + s.dur) / 1000).toStringAsFixed(1)} ms');
  final scavenges = gcs.where((g) => g.name == 'CollectNewGeneration').toList();
  final mourns = gcs.where((g) => g.name == 'MournWeakHandles').toList();
  if (scavenges.isNotEmpty) {
    final avg = scavenges.fold<int>(0, (a, g) => a + g.dur) / scavenges.length / 1000;
    final mavg = mourns.isEmpty ? 0.0 : mourns.fold<int>(0, (a, g) => a + g.dur) / mourns.length / 1000;
    stdout.writeln('== scavenges: ${scavenges.length} in ${seconds}s, avg ${avg.toStringAsFixed(2)} ms, '
        'max ${(scavenges.first.dur / 1000).toStringAsFixed(2)} ms; MournWeakHandles avg ${mavg.toStringAsFixed(2)} ms');
  }
  for (final g in gcs.take(6)) {
    stdout.writeln('     gc ${(g.dur / 1000).toStringAsFixed(2)} ms  ${g.name}  @${((g.ts - t0) / 1e6).toStringAsFixed(2)}s');
  }
  // The longest spans of any kind, as a fallback when no frame span matched
  // and as the quickest picture of what is big.
  final byLen = spans.where((s) => s.name != 'Frame').toList()
    ..sort((a, b) => b.dur.compareTo(a.dur));
  stdout.writeln('== longest spans:');
  final seenNames = <String>{};
  for (final s in byLen) {
    if (!seenNames.add(s.name)) continue;
    stdout.writeln('     ${(s.dur / 1000).toStringAsFixed(2).padLeft(7)} ms  t${s.tid}  ${s.name}${s.cat.isEmpty ? '' : '  [${s.cat}]'}');
    if (seenNames.length >= 16) break;
  }

  for (final f in long.take(12)) {
    stdout.writeln('-- frame @${((f.ts - t0) / 1e6).toStringAsFixed(2)}s  ${(f.dur / 1000).toStringAsFixed(1)} ms');
    // Everything on any thread overlapping this frame, longest first.
    final inside = spans
        .where((s) => s.name != 'Frame' && s.ts < f.ts + f.dur && s.ts + s.dur > f.ts && s.dur >= 300)
        .toList()
      ..sort((a, b) => b.dur.compareTo(a.dur));
    final seen = <String>{};
    for (final s in inside) {
      final key = '${s.tid}/${s.name}';
      if (!seen.add(key)) continue;
      stdout.writeln('     ${(s.dur / 1000).toStringAsFixed(2).padLeft(7)} ms  t${s.tid}  ${s.name}${s.cat.isEmpty ? '' : '  [${s.cat}]'}');
      if (seen.length >= 14) break;
    }
  }

  // What was allocated in the window, by class: the scavenge rate is the
  // allocation rate, and MournWeakHandles scales with the live native-backed
  // objects (each carries a finalizer handle), so both columns matter.
  final before = <String, ClassHeapStats>{
    for (final m in allocBefore.members ?? const <ClassHeapStats>[])
      '${m.classRef?.id}': m,
  };
  final deltas = <({String name, int bytes, int inst, int live})>[];
  for (final m in alloc.members ?? const <ClassHeapStats>[]) {
    final b = before['${m.classRef?.id}'];
    final bytes = (m.accumulatedSize ?? 0) - (b?.accumulatedSize ?? 0);
    final inst = (m.instancesAccumulated ?? 0) - (b?.instancesAccumulated ?? 0);
    if (bytes <= 0 && inst <= 0) continue;
    deltas.add((name: '${m.classRef?.name}', bytes: bytes, inst: inst, live: m.instancesCurrent ?? 0));
  }
  deltas.sort((a, b) => b.bytes.compareTo(a.bytes));
  final totalBytes = deltas.fold<int>(0, (a, d) => a + d.bytes);
  final frameCount = frames.isEmpty ? 1 : frames.length;
  stdout.writeln('== allocated in window: ${(totalBytes / 1048576).toStringAsFixed(1)} MB '
      '(${(totalBytes / 1048576 / seconds).toStringAsFixed(2)} MB/s, '
      '${(totalBytes / 1024 / frameCount).toStringAsFixed(0)} KB/frame)');
  for (final d in deltas.take(22)) {
    stdout.writeln('     ${(d.bytes / 1024).toStringAsFixed(0).padLeft(8)} KB  '
        '${d.inst.toString().padLeft(8)} inst  ${d.name}  (live ${d.live})');
  }
  // By instance count: the native wrappers the scavenger finalises are
  // tiny, so they never make the byte list, but a per-frame one shows here.
  final byInst = deltas.toList()..sort((a, b) => b.inst.compareTo(a.inst));
  stdout.writeln('== most instances allocated in window (per frame):');
  for (final d in byInst.take(30)) {
    stdout.writeln('     ${d.inst.toString().padLeft(8)}  ${(d.inst / frameCount).toStringAsFixed(1).padLeft(7)}/frame  ${d.name}');
  }
  // Native-backed classes carry a finalizer handle each, and the scavenger
  // walks every handle (MournWeakHandles): their LIVE count is the price.
  stdout.writeln('== native-backed / external live instances:');
  const watch = ['DeviceBuffer', 'Texture', 'Shader', 'RenderPipeline', 'RenderPass',
    'CommandBuffer', 'HostBuffer', 'Paragraph', 'Image', 'Picture', 'Path', 'Paint',
    'TransferableTypedData', 'Pointer', 'NativeFinalizer', 'Finalizer', 'WeakReference'];
  for (final m in alloc.members ?? const <ClassHeapStats>[]) {
    final n = '${m.classRef?.name}';
    if (watch.contains(n) || n.contains('External') || n.startsWith('_External')) {
      stdout.writeln('     ${(m.instancesCurrent ?? 0).toString().padLeft(8)}  $n');
    }
  }
  final heaps = alloc.json?['_heaps'];
  stdout.writeln('== heaps: $heaps');
  final live = (alloc.members ?? const <ClassHeapStats>[]).toList()
    ..sort((a, b) => (b.instancesCurrent ?? 0).compareTo(a.instancesCurrent ?? 0));
  stdout.writeln('== most live instances:');
  for (final m in live.take(14)) {
    stdout.writeln('     ${(m.instancesCurrent ?? 0).toString().padLeft(8)}  ${m.classRef?.name}');
  }
  await vm.dispose();
}
